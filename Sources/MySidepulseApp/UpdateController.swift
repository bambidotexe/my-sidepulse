import AppKit
import os
import MySidepulseCore
import MySidepulsePlatform

/// The update feature's one owner. It looks for a release on its own (`UpdateSchedule`: shortly after
/// launch, then weekly) and when the Settings button asks; a release found without being asked for is
/// announced by a notification. Update, from the notification or from Settings, opens one window that
/// fetches the release and makes it ready while the app is still running; "Install and Relaunch" then
/// hands two folders to a helper and quits the app the way the menu's Quit does, which turns the
/// strip off. The rules are Core's (`UpdatePanel`, `UpdateSession`, `StagedUpdateCheck`,
/// `UpdateInstallScript`); this object runs the requests and picks the sentences.
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// Settings › General › Updates.
    @Published private(set) var panel = UpdatePanel()
    /// The update window; nil while there is none.
    @Published private(set) var session: UpdateSession?
    /// How the last Install and Relaunch ended, from this launch until the user closes the window that
    /// says so.
    @Published private(set) var outcome: UpdateResult?

    var onShowSettings: (() -> Void)?
    /// Whether another window still needs the app active once the update window goes away.
    var othersNeedUsActive: () -> Bool = { false }

    /// Empty for a binary run outside its bundle, which `UpdateCheck.decide` reads as up to date.
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    private static var directory: URL { Paths.updates }
    private static var resultFile: URL { directory.appendingPathComponent("result") }

    /// Whether an install has left an outcome this launch has not read yet. The launch that follows an
    /// install is the helper's doing, not a person's, so it opens the window that says how it ended and
    /// nothing else. Read without touching anything: `readLastInstall` is what consumes it.
    static var installOutcomeIsWaiting: Bool {
        guard let written = (try? FileManager.default.attributesOfItem(atPath: resultFile.path)[.modificationDate]) as? Date
        else { return false }
        return UpdateResult.isNews(age: Date().timeIntervalSince(written))
    }

    /// Leaves the mark that says a version read the outcome, for a copy that is about to hand itself to
    /// launchd and quit before it could read anything. The helper reads a version that is gone without that
    /// mark as one that crashed on its way up, and would put the previous one back; this one started, and
    /// is standing aside for the copy launchd runs, which finds the outcome itself and says so.
    static func noteStartedBeforeHandingOver() {
        guard installOutcomeIsWaiting else { return }
        FileManager.default.createFile(atPath: UpdateResult.readMark(for: resultFile).path, contents: nil)
    }

    private let notifier = UpdateNotifier()
    private var schedule = UpdateSchedule()
    private var checkInFlight = false
    /// A press arrived while a check nobody had asked for was in flight: its answer is now awaited.
    private var answerIsAwaited = false
    /// The notification was clicked before this run had asked GitHub: the answer opens the window.
    private var presentWhenFound = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var download: UpdateDownload?
    /// Bumped whenever a session ends or starts over, so that a fetch or an unpacking that ends late is
    /// dropped.
    private var generation = 0
    private var diskImage: URL?
    private var stagedApp: URL?
    /// The install helper, from the click on Install and Relaunch until this app quits or gives up on
    /// quitting.
    private var helper: Int32?
    private var window: UpdateWindowController?
    /// One unpacking at a time: two would share the mount point and the `staged` folder, and a Cancel
    /// followed at once by Update starts a second while the first is still winding down.
    private static let stagingQueue = DispatchQueue(label: "io.mysidepulse.app.update.staging", qos: .userInitiated)

    var windowIsUp: Bool { window?.isUp == true }

    // MARK: - Launch

    /// Reads how the last Install and Relaunch ended, then starts the schedule.
    func start() {
        notifier.onUpdateRequested = { [weak self] in self?.presentUpdate() }
        notifier.start()
        readLastInstall()
        timer = Timer.scheduledTimer(withTimeInterval: K.updateLaunchDelaySeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            self.timer = Timer.scheduledTimer(withTimeInterval: K.updateTickSeconds, repeats: true) { [weak self] _ in
                self?.tick()
            }
            self.timer?.tolerance = 60
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tick()
        }
    }

    /// The helper's one line. It is renamed rather than removed: the helper, which may still be watching
    /// this launch, reads that mark as "the new version had started" if the app is gone again a moment
    /// later. A line that is no longer news was left behind by an install nobody is waiting on any more.
    private func readLastInstall() {
        let files = FileManager.default
        let mark = UpdateResult.readMark(for: Self.resultFile)
        try? files.removeItem(at: mark)
        let line = try? String(contentsOf: Self.resultFile, encoding: .utf8)
        let written = (try? files.attributesOfItem(atPath: Self.resultFile.path)[.modificationDate]) as? Date
        try? files.moveItem(at: Self.resultFile, to: mark)
        sweep()
        guard let line else { return }
        guard let written, UpdateResult.isNews(age: Date().timeIntervalSince(written)) else {
            Log.app.notice("update: an install result left behind is ignored: \(line, privacy: .public)")
            return
        }
        switch UpdateResult(line: line) {
        case .installed(let version):
            Log.app.notice("update: version \(version, privacy: .public) installed")
            present(.installed(version: version))
        case .failed(let version, let reason):
            Log.app.error("update: version \(version, privacy: .public) NOT installed (\(reason.rawValue, privacy: .public)); still \(self.appVersion, privacy: .public)")
            panel.installFailed(Self.words(for: reason))
            present(.failed(version: version, reason: reason))
        case nil:
            Log.app.error("update: unreadable install result: \(line, privacy: .public)")
        }
    }

    // MARK: - Checks

    private func tick() {
        guard !checkInFlight, session == nil, schedule.isDue(now: Date()) else { return }
        runCheck(asked: false)
    }

    /// The Settings button.
    func press() {
        switch panel.press() {
        case .check:
            if checkInFlight { answerIsAwaited = true } else { runCheck(asked: true) }
        case .update(let release):
            begin(release)
        case nil:
            break
        }
    }

    private func runCheck(asked: Bool) {
        checkInFlight = true
        UpdateChecker.check(current: appVersion) { [weak self] result in
            DispatchQueue.main.async { self?.checkEnded(result, asked: asked) }
        }
    }

    private func checkEnded(_ result: Result<UpdateDecision, Error>, asked: Bool) {
        checkInFlight = false
        let asked = asked || answerIsAwaited
        answerIsAwaited = false
        switch result {
        case .success(let decision):
            schedule.answered(at: Date())
            Log.app.notice("update check (\(asked ? "asked" : "automatic", privacy: .public)): \(Self.logLine(decision), privacy: .public)")
            if asked {
                panel.checked(decision)
            } else {
                panel.autoChecked(decision)
                if case .available(let release) = decision {
                    notifier.postUpdateAvailable(version: release.version.displayString)
                }
            }
        case .failure(let error):
            schedule.failed(at: Date())
            Log.app.notice("update check (\(asked ? "asked" : "automatic", privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            if asked { panel.checkFailed(error.localizedDescription) }
        }
        guard presentWhenFound else { return }
        presentWhenFound = false
        if let release = panel.pendingRelease { begin(release) } else { onShowSettings?() }
    }

    private static func logLine(_ decision: UpdateDecision) -> String {
        switch decision {
        case .upToDate: "up to date"
        case .noRelease: "no release published"
        case .available(let release): "version \(release.version.displayString) available"
        }
    }

    // MARK: - The update window

    /// The notification's Update, and a click on the notification itself. Same thing as the Settings
    /// button once it reads Update; a notification left by an earlier run asks GitHub first, then opens
    /// the window on the answer.
    func presentUpdate() {
        if session != nil { showWindow(); return }
        guard let release = panel.pendingRelease else {
            presentWhenFound = true
            press()
            return
        }
        begin(release)
    }

    private func begin(_ release: LatestRelease) {
        if session == nil {
            session = UpdateSession(release: release)
            outcome = nil
            startDownload(release)
        }
        showWindow()
    }

    private func showWindow() {
        if window == nil { window = UpdateWindowController(controller: self) }
        window?.show()
    }

    /// The window that asked for the update says how it ended, at the launch that follows it. It is the
    /// whole news: no other window opens behind it, and the app is otherwise back exactly as it was.
    private func present(_ outcome: UpdateResult) {
        self.outcome = outcome
        showWindow()
    }

    /// The button on that window.
    func dismissOutcome() {
        outcome = nil
        window?.close()
    }

    private func startDownload(_ release: LatestRelease) {
        generation += 1
        let current = generation
        sweep()
        let destination = Self.directory.appendingPathComponent("MySidepulse-\(release.version.displayString).dmg")
        Log.app.notice("update: downloading \(release.dmgURL.absoluteString, privacy: .public)")
        let download = UpdateDownload(release: release, destination: destination, onProgress: { [weak self] received, expected in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.session?.received(received, of: expected)
            }
        }, onDone: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.downloadEnded(result)
            }
        })
        self.download = download
        download.start()
    }

    private func downloadEnded(_ result: Result<URL, Error>) {
        download = nil
        switch result {
        case .failure(let error):
            Log.app.error("update download failed: \(String(describing: error), privacy: .public)")
            session?.failed(Self.words(for: error))
        case .success(let image):
            Log.app.notice("update: downloaded \(image.lastPathComponent, privacy: .public)")
            diskImage = image
            session?.downloaded()
            if let obstacle = UpdateInstaller.obstacle(updatesDirectory: Self.directory) {
                Log.app.notice("update: the app cannot replace itself here (\(obstacle.rawValue, privacy: .public)); the disk image is the way")
                session?.cannotReplace()
            } else {
                prepare(image)
            }
        }
    }

    /// Unpacks and checks the release off the main actor; only a copy that passed everything enables
    /// the button.
    private func prepare(_ image: URL) {
        let current = generation
        let directory = Self.directory
        let stager = UpdateStager(bundleIdentifier: Bundle.main.bundleIdentifier ?? "", runningVersion: appVersion,
                                  log: { Log.app.notice("update: \($0, privacy: .public)") })
        Self.stagingQueue.async { [weak self] in
            let outcome = Result { try stager.stage(diskImage: image, in: directory) }
            DispatchQueue.main.async {
                // Cancelled meanwhile: what it unpacked is swept when the next fetch starts, never here,
                // where a later unpacking may already be filling the same folder.
                guard let self, self.generation == current else { return }
                switch outcome {
                case .success(let staged):
                    self.stagedApp = staged
                    self.session?.prepared()
                    Log.app.notice("update: ready to install")
                case .failure(let error):
                    Log.app.error("update: preparing failed: \(String(describing: error), privacy: .public)")
                    self.session?.failed(Self.words(for: error))
                }
            }
        }
    }

    func retry() {
        guard var current = session, current.retry() else { return }
        session = current
        startDownload(current.release)
    }

    /// Cancel, and the window's close button.
    func cancel() {
        guard session?.canCancel == true else { return }
        endSession(sweeping: true)
        Log.app.notice("update: cancelled")
        window?.close()
    }

    /// The window is going away on its own (its close button).
    func windowClosed() {
        if session?.canCancel == true {
            endSession(sweeping: true)
            Log.app.notice("update: cancelled")
        }
        outcome = nil
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    /// The way out when the app cannot replace itself: macOS mounts the image and shows its
    /// Applications link.
    func openDiskImage() {
        guard let image = diskImage else { return }
        Log.app.notice("update: opening \(image.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.open(image)
        endSession(sweeping: false)
        window?.close()
    }

    private func endSession(sweeping: Bool) {
        generation += 1
        download?.cancel()
        download = nil
        session = nil
        stagedApp = nil
        diskImage = nil
        if sweeping { sweep() }
    }

    private func sweep() { UpdateInstaller.sweep(Self.directory) }

    // MARK: - Install and Relaunch

    func installAndRelaunch() {
        guard let current = session, current.canInstall, let staged = stagedApp else { return }
        let bundle = Bundle.main.bundleURL
        guard FileManager.default.fileExists(atPath: staged.path),
              UpdateInstaller.obstacle(updatesDirectory: Self.directory) == nil else {
            Log.app.error("update: the prepared copy is gone or the app can no longer be replaced")
            session?.failed(Self.words(for: .replace))
            return
        }
        let plan = UpdateInstallPlan(
            pid: getpid(), destination: bundle, staged: staged,
            backup: Self.directory.appendingPathComponent("previous/\(bundle.lastPathComponent)"),
            resultFile: Self.resultFile, logFile: Self.directory.appendingPathComponent("install.log"),
            executableName: Bundle.main.executableURL?.lastPathComponent ?? "MySidepulseApp",
            version: current.release.version.displayString,
            // The job is how the app comes back, whenever there is one: started any other way it would be
            // nobody's job, and no crash would bring it back. It is asked for even when this process is not
            // the job itself, because then the copy `open` would start has to bootstrap the agent and hand
            // over, and the copy that finally stays is launchd's either way. `kickstart` on a job that is
            // not loaded fails, and the helper opens the bundle instead.
            launchdService: LoginService.isEnabled ? "gui/\(getuid())/\(LoginService.jobLabel)" : nil)
        do {
            helper = try UpdateInstaller.start(plan, script: Self.directory.appendingPathComponent("install.sh"))
        } catch {
            Log.app.error("update: the install helper could not be started: \(String(describing: error), privacy: .public)")
            session?.failed(Self.words(for: .replace))
            return
        }
        _ = session?.install()
        // The helper starts the new version, and a launch nobody asked for opens no window: the marker says
        // so, and the hand-over that may follow leaves it for the copy that stays (`QuietLaunch`).
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.quietLaunch.path, contents: nil)
        Log.app.notice("update: installing \(plan.version, privacy: .public); quitting")
        // An app that is still here after `K.updateStallNoticeSeconds` stops the helper before it says so,
        // so that a quit that comes later is only ever a quit. What was prepared is still good.
        DispatchQueue.main.asyncAfter(deadline: .now() + K.updateStallNoticeSeconds) { [weak self] in
            guard let self, self.session?.phase == .installing else { return }
            if let helper = self.helper { UpdateInstaller.stop(helper) }
            self.helper = nil
            Log.app.error("update: the app did not quit; helper stopped, install abandoned")
            self.session?.installStalled()
        }
        // The menu's Quit: `applicationShouldTerminate` turns the strip off on the way out.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Words

    static func words(for reason: UpdateResult.Reason) -> String {
        switch reason {
        case .replace: Loc.update.couldNotReplace
        case .launch: Loc.update.didNotStart
        case .stranded: Loc.update.stranded
        }
    }

    static func words(for error: Error) -> String {
        if error as? UpdateDownload.Failure == .damaged { return Loc.update.damagedDownload }
        guard let error = error as? UpdateStager.StagingError else { return error.localizedDescription }
        return switch error {
        case .cannotOpenImage: Loc.update.cannotOpenImage
        case .appMissing, .rejected(.wrongApp): Loc.update.appMissing
        case .rejected(.notNewer): Loc.update.notNewer
        case .rejected(.needsNewerSystem(let system)): Loc.update.needsNewerSystem(system)
        case .signature(.differentSigner): Loc.update.differentSigner
        case .signature(.invalid): Loc.update.invalidSignature
        }
    }
}

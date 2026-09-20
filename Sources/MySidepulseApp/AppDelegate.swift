import AppKit
import ServiceManagement
import MySidepulseCore
import MySidepulsePlatform

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine!
    private var menuBar: MenuBarController!
    private var powerMonitor: PowerMonitor!
    private var deviceMonitor: DeviceMonitor!
    private var controlServer: ControlServer?
    private let settingsModel = SettingsModel()
    private var settingsWindow: SettingsWindow?
    /// When this launch began, if the installer asked for a quiet one. An open request that arrives
    /// within `QuietLaunch.reopenGrace` of it is that install's, not a person's (`QuietLaunch`).
    private var quietLaunchAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would fight over socket and journal.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.mysidepulse.app")
        if running.contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        // A reinstall opens the bundle as well, and the window that got was one nobody asked for. The
        // installer says so with a marker, which is read here but **not removed here**: the hand-over
        // below quits within the second, and the copy launchd starts in its place has to find the marker
        // too, because the open request outlives the process it was sent to and is delivered again to it.
        // It is removed further down, by whichever copy is the one that stays.
        if let written = (try? FileManager.default.attributesOfItem(atPath: Paths.quietLaunch.path))?[.modificationDate] as? Date,
           QuietLaunch.isFresh(writtenAt: written, now: Date()) {
            quietLaunchAt = Date()
        }
        // An update says the same a second way, which holds whatever version wrote what is in `updates/`:
        // while an install's outcome is unread, this launch is that install's and nobody's request.
        if UpdateController.installOutcomeIsWaiting { quietLaunchAt = Date() }

        var config = AppConfig.load()
        // One LaunchAgent is both open-at-login and crash restart, which is
        // the difference between a crash costing a few seconds and costing
        // the rest of the day.
        LoginService.migrateFromLoginItem()
        // (Re)install the agent on any launch that did not come from it —
        // `open`, `make install`, a double-click — so the plist always points at
        // the copy that is actually running and the job is freshly bootstrapped.
        // Skipped when launchd started us, where booting the job out would pull
        // the rug from under the process running this code. Only an explicit
        // `false` — the menu checkbox — stops it.
        if config.autoRestartWanted != false, !LoginService.launchedByOwnAgent {
            do {
                try LoginService.install()
                config.autoRestartWanted = true
                config.save()
                // The job is bootstrapped, but this process is not it: launchd's own spawn found us
                // already running and stood down, as a second copy must. Hand over, so that what runs
                // is what launchd supervises. Done here, before the menu bar and the strip are built,
                // so the hand-over is a blink rather than a window that opens and closes.
                if LoginService.handOverToLaunchd() {
                    // The marker stays for the copy launchd is about to start, and so does an install's
                    // outcome; what this copy leaves is the mark saying a version did start, so that the
                    // update helper does not read this quit as a crash.
                    UpdateController.noteStartedBeforeHandingOver()
                    NSApp.terminate(nil)
                    return
                }
            } catch {
                // Leave the flag unset so the next launch retries. Recording a
                // failed registration as settled would strand the user with a
                // permanent doctor FAIL and no self-heal.
                Log.app.error(
                    "could not register the launch agent: \(String(describing: error), privacy: .public)")
            }
        }

        // This copy is the one that stays, so the marker has done its work and must not silence the next
        // launch, which will be a person opening the app.
        if quietLaunchAt != nil { try? FileManager.default.removeItem(at: Paths.quietLaunch) }

        UserDefaults.standard.register(defaults: [MenuBarController.visiblePrefKey: true])
        buildMainMenu()

        engine = Engine(config: config)
        Log.app.notice("mysidepulse started: mode=\(self.engine.mode.configValue, privacy: .public)")
        menuBar = MenuBarController()
        menuBar.engine = engine
        menuBar.openSettings = { [weak self] in self?.showSettings() }
        menuBar.setup()
        settingsModel.engine = engine
        // The menu still rebuilds lazily via NSMenuDelegate; the settings
        // window coalesces these into at most one refresh per runloop turn.
        engine.onStateChanged = { [weak self] in self?.settingsModel.stateChanged() }

        let controlServer = ControlServer(socketPath: Paths.controlSocket.path)
        self.controlServer = controlServer
        controlServer.handler = { [weak self] request in
            DispatchQueue.main.sync {
                self?.engine.controlResponse(for: request) {
                    LoginService.statusDescription
                } ?? ControlResponse(ok: false, error: "shutting down")
            }
        }
        // Retry rather than run headless for the rest of the process: a bind
        // that fails once must not cost the CLI — status, led, doctor,
        // notify — until someone restarts the app. `stop()` only unlinks a
        // socket this instance actually owns, so retrying cannot strand a
        // live instance's CLI either.
        controlServer.startRetrying(every: K.controlRetrySeconds) { error in
            Log.app.error(
                "control server unavailable: \(String(describing: error), privacy: .public)")
        }

        powerMonitor = PowerMonitor()
        powerMonitor.onChange = { [weak self] power in self?.engine.powerChanged(power) }
        deviceMonitor = DeviceMonitor()
        deviceMonitor.onAppear = { [weak self] device in self?.engine.deviceAppeared(device) }
        deviceMonitor.onDisappear = { [weak self] key in self?.engine.deviceGone(key) }

        engine.start()
        powerMonitor.start()
        // Wake is a state discontinuity: deadlines may be long past and CPU
        // samples span time the machine slept through. One sync sorts both.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.engine.machineWoke()
        }
        // Discover devices only after the engine has replayed the journal and
        // pruned dead sessions: main-queue FIFO puts this block after the ones
        // engine.start() queued. Until it runs no device is registered, so the
        // app cannot paint the strip before it knows what to show.
        DispatchQueue.main.async { [weak self] in
            self?.deviceMonitor.start()
        }

        // Last: a launch that follows an Install and Relaunch opens Settings on the new version.
        UpdateController.shared.onShowSettings = { [weak self] in self?.showSettings() }
        UpdateController.shared.othersNeedUsActive = { [weak self] in self?.settingsWindow?.isUp == true }
        UpdateController.shared.start()
    }

    /// Every quit comes through here — the menu bar item, ⌘Q, the Settings
    /// button — so every quit turns the strip off. The engine is nil in the
    /// second copy that terminates itself at launch: it owns no strips, and
    /// must not darken the ones the live copy is painting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine?.blackoutForQuit()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// Double-clicking the app in Finder, or its Dock icon with the window
    /// gone, means "show me the app" — for a menu bar app, that is Settings.
    /// With the menu bar item hidden it is also the only way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if let quietLaunchAt, QuietLaunch.silences(reopenAt: Date(), quietLaunchAt: quietLaunchAt) {
            // The installer's own open request, arriving after the hand-over. Nobody asked for a window.
            self.quietLaunchAt = nil
            return true
        }
        if !flag { showSettings() }
        return true
    }

    // MARK: settings window

    /// Built once and re-shown: the window keeps its page, its position and its model across
    /// closes. Every caller is already on main; `SettingsWindow` is main-actor isolated and says so.
    func showSettings() {
        MainActor.assumeIsolated {
            if settingsWindow == nil {
                settingsWindow = SettingsWindow(model: settingsModel)
            }
            settingsWindow?.show()
        }
    }

    @objc private func showSettingsAction(_ sender: Any?) { showSettings() }

    /// An LSUIElement app has no main menu by default, which silently breaks
    /// Cmd-C/V in the settings window's text fields and Cmd-W on the window.
    /// This is the minimal menu that makes the window behave like a window.
    private func buildMainMenu() {
        let t = Loc.mainMenu
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t.about,
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: Loc.menu.settings,
                                  action: #selector(showSettingsAction(_:)),
                                  keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: Loc.menu.quit,
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: t.edit)
        edit.addItem(withTitle: t.undo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: t.redo, action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: t.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: t.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: t.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: t.selectAll, action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: t.window)
        windowMenu.addItem(withTitle: t.close, action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: t.minimize,
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

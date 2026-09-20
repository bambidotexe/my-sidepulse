import AppKit
import ServiceManagement
import MySidepulseCore
import MySidepulsePlatform

extension UserDefaults {
    /// Named after its key, which is what lets `observe` watch it.
    @objc dynamic var showInMenuBar: Bool { bool(forKey: MenuBarController.visiblePrefKey) }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    static let visiblePrefKey = "showInMenuBar"

    private var statusItem: NSStatusItem!
    private var visibility: NSKeyValueObservation?
    weak var engine: Engine?
    var openSettings: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.icon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // The preference is the one owner of visibility, watched rather than
        // pushed, so the settings toggle and `defaults write` both land here.
        // Set once up front so a hidden item never flashes at launch; a change
        // made by another process is reported off the main thread.
        apply(visible: UserDefaults.standard.showInMenuBar)
        visibility = UserDefaults.standard.observe(\.showInMenuBar, options: [.new]) {
            [weak self] defaults, _ in
            DispatchQueue.main.async { self?.apply(visible: defaults.showInMenuBar) }
        }
    }

    /// Logged because a hidden item is an app with no visible trace: the log
    /// is then the only place that says it is running that way on purpose.
    private func apply(visible: Bool) {
        guard statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
        Log.app.notice("menu bar item \(visible ? "shown" : "hidden", privacy: .public)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let engine else { return }
        let t = Loc.menu

        let auto = NSMenuItem(title: t.ledsAuto, action: #selector(setAuto), keyEquivalent: "")
        auto.target = self
        auto.state = engine.mode == .auto ? .on : .off
        menu.addItem(auto)
        let off = NSMenuItem(title: t.ledsOff, action: #selector(setOff), keyEquivalent: "")
        off.target = self
        off.state = engine.mode == .off ? .on : .off
        menu.addItem(off)
        if case .color(let hex) = engine.mode {
            let forced = NSMenuItem(title: t.ledsForced(hex), action: nil, keyEquivalent: "")
            forced.state = .on
            menu.addItem(forced)
        }
        if case .effect(let name) = engine.mode {
            let playing = NSMenuItem(title: t.ledsEffect(name), action: nil, keyEquivalent: "")
            playing.state = .on
            menu.addItem(playing)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: t.openAtLogin, action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = engine.autoRestartIsOn ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        for line in statusLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: t.settings, action: #selector(openSettingsItem),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: t.quit, action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func openSettingsItem() { openSettings?() }

    private func statusLines() -> [String] {
        guard let engine else { return [] }
        let t = Loc.menu
        let response = engine.controlResponse(for: ControlRequest(cmd: "status")) { "" }
        var lines: [String] = []
        let devices = response.devices ?? []
        lines.append(devices.isEmpty ? t.noDeviceMounted
            : devices.map { t.deviceSummary(name: $0.name, leds: $0.leds, stalled: $0.stalled) }
                .joined(separator: ", "))
        let sessions = response.sessions ?? []
        if sessions.isEmpty {
            lines.append(t.noSessions)
        } else {
            let counts = Dictionary(grouping: sessions, by: \.state)
                .map { "\($0.value.count) \($0.key)" }
                .sorted()
                .joined(separator: ", ")
            lines.append(t.sessionsLine(counts))
        }
        // Third line of the readout: device presence, session summary,
        // last event age — the one that says whether hooks are arriving at all.
        lines.append(response.lastEventAgeSeconds.map { t.lastEventAgo(seconds: $0) }
            ?? t.lastEventNone)
        return lines
    }

    @objc private func setAuto() { engine?.mode = .auto }
    @objc private func setOff() { engine?.mode = .off }
    /// Also the auto-restart switch: one registration covers both, so turning
    /// this off means the app neither starts at login nor comes back from a
    /// crash. That is the honest behaviour for "don't run this by itself".
    @objc private func toggleLogin() {
        guard let engine else { return }
        engine.setAutoRestart(!engine.autoRestartIsOn)
    }

    /// The strip, drawn rather than shipped as an asset so it rebuilds from
    /// source.
    ///
    /// Two dots, each centred on the arc of the end cap that wraps it, so dot
    /// and cap are concentric. The diameter is then *solved* rather than
    /// chosen: requiring the gap between the dots to equal the gap around them
    /// gives `d = 4c - H`, which makes every gap in the icon identical — above,
    /// below, between, and at both ends (1.7pt at this size). Three dots have
    /// no such solution on an 18pt canvas — any placement looks slightly
    /// adrift however the numbers are nudged.
    static func icon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let midX = side / 2
            let midY = side / 2
            let strokeWidth: CGFloat = 1.3

            let bodyWidth: CGFloat = 17
            let bodyHeight: CGFloat = 10
            let body = NSBezierPath(
                roundedRect: NSRect(x: midX - bodyWidth / 2,
                                    y: midY - bodyHeight / 2,
                                    width: bodyWidth,
                                    height: bodyHeight),
                xRadius: bodyHeight / 2,
                yRadius: bodyHeight / 2)
            body.lineWidth = strokeWidth
            NSColor.black.setStroke()
            body.stroke()

            let capCentreOffset = (bodyWidth - bodyHeight) / 2
            let innerHeight = bodyHeight - strokeWidth
            let dotDiameter = 4 * capCentreOffset - innerHeight
            NSColor.black.setFill()
            for offset in [-capCentreOffset, capCentreOffset] {
                NSBezierPath(ovalIn: NSRect(x: midX + offset - dotDiameter / 2,
                                            y: midY - dotDiameter / 2,
                                            width: dotDiameter,
                                            height: dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

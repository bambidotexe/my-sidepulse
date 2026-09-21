import AppKit
import SwiftUI
import MySidepulseCore

// MARK: - The pages

/// The pages, in toolbar order. The raw value is the toolbar item's identifier, so the toolbar and the
/// selection cannot disagree about which page a click means.
///
/// One case per page. A page is a SUBJECT the user thinks in (the strip, the phone), never a kind
/// of control. General comes first. What the app needs from outside itself (Claude Code's hooks,
/// the terminal hook, the notification permission) comes as "System", then whether all of it works,
/// as "Health", and the tip jar last.
enum SettingsPageID: String, CaseIterable, Sendable {
    case general, strip, notifications, playground, system, health, tip

    /// The toolbar item's label, and the window's title while the page is shown. Title Case.
    var title: String {
        let t = Loc.settings
        switch self {
        case .general: return t.pageGeneral
        case .strip: return t.pageStrip
        case .notifications: return t.pageNotifications
        case .playground: return t.pagePlayground
        case .system: return t.pageSystem
        case .health: return t.pageHealth
        case .tip: return t.pageTip
        }
    }

    /// The SF Symbol drawn above the title. One symbol per page, in the outline style the system's
    /// own settings toolbars use, picturing the subject rather than decorating it.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .strip: "light.strip.2"
        case .notifications: "bell.badge"
        case .playground: "paintpalette"
        case .system: "checkmark.shield"
        case .health: "stethoscope"
        case .tip: "mug"
        }
    }
}

/// What the window and its one SwiftUI root share: which page is shown, set by the toolbar, and where
/// the page's measured height goes, set by the window.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var page: SettingsPageID = .general
    /// Called with the shown page's natural height whenever it changes: on a page switch, and when a
    /// page gains or loses a line of its own.
    var pageHeightChanged: ((CGFloat) -> Void)?
}

/// How tall the shown page wants to be, read from behind the page.
private struct SettingsPageHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The window's one SwiftUI root: the shown page, measured, in a scroll view.
struct SettingsRootView: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var model: SettingsModel

    var body: some View {
        // The page scrolls because the window's height is capped to what fits on the screen: on a
        // short display a long page is scrolled rather than cut off.
        ScrollView(.vertical) {
            page
                .frame(width: SettingsMetrics.contentWidth, alignment: .topLeading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SettingsPageHeight.self, value: proxy.size.height)
                    }
                }
        }
        .frame(width: SettingsMetrics.contentWidth)
        .onPreferenceChange(SettingsPageHeight.self) { [selection] height in
            // Preferences are delivered while SwiftUI updates, which is on the main actor.
            MainActor.assumeIsolated { selection.pageHeightChanged?(height) }
        }
    }

    /// One page view per case, each a `SettingsPage` of groups built from the kit.
    @ViewBuilder private var page: some View {
        switch selection.page {
        case .general: GeneralPage(model: model)
        case .strip: StripPage(model: model)
        case .notifications: NotificationsPage(model: model)
        case .playground: PlaygroundPage(model: model)
        case .system: SystemPage(model: model)
        case .health: HealthPage(model: model)
        case .tip: TipPage()
        }
    }
}

// MARK: - The window

/// The pages are picked from a real `NSToolbar`: `toolbarStyle = .preference` draws each page's symbol
/// ABOVE its title, and the window's title is the shown page's. One `NSHostingController` for the whole
/// window; the toolbar sets a page on `SettingsSelection` and the SwiftUI root swaps it in.
///
/// The window's height follows the page and its width never moves. The page reports its natural height
/// and the window resizes to it around its own TOP-LEFT corner, animated: on a page switch, and equally
/// when a page gains a line of its own (a warning that appears, an error row).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let selection = SettingsSelection()
    private let model: SettingsModel
    private let hosting: NSHostingController<SettingsRootView>

    /// What the window is sized to, in content points. Zero until the page has been measured once.
    private var contentHeight: CGFloat = 0
    /// Whether the window has been sized and centred. Until it has, a reported height is recorded and
    /// nothing moves: `show()` is what centres, and it must do so at the right size.
    private var hasBeenPlaced = false
    private var resizePending = false

    /// The height the window is laid out at while the first page is measured. Any value works.
    private static let measuringHeight: CGFloat = 480
    /// How much of the screen's height the window leaves alone; a taller page scrolls instead.
    private static let screenAllowance: CGFloat = 140

    init(model: SettingsModel) {
        self.model = model
        // Titled, closable, miniaturizable. NOT resizable: the width is fixed and the height is the page's.
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = selection.page.title
        window.isReleasedWhenClosed = false
        hosting = NSHostingController(rootView: SettingsRootView(selection: selection, model: model))
        // The height is this class's to animate. A hosting controller that also constrains the window
        // to its content fights every resize.
        hosting.sizingOptions = []
        super.init()
        selection.pageHeightChanged = { [weak self] height in self?.pageReported(height) }
        window.contentViewController = hosting
        window.delegate = self
        installToolbar()
    }

    var isUp: Bool { window.isVisible }

    /// Whether another window of the app still needs it active once this one goes away: the
    /// onboarding wizard, which the System page and a first launch open. Injected, never inferred
    /// from `NSApp.windows`.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    /// Opens the window on a named page. The onboarding's Phone alerts row lands the user on
    /// Notifications, where the QR code their phone scans is.
    func show(page: SettingsPageID) {
        selection.page = page
        window.title = page.title
        window.toolbar?.selectedItemIdentifier = identifier(for: page)
        show()
    }

    func show() {
        // Sized BEFORE it is centred, never after: a hosting controller does not size the window until
        // its view lays out, and centring a zero-width window puts its origin mid-screen.
        if !hasBeenPlaced {
            window.setContentSize(NSSize(width: SettingsMetrics.contentWidth, height: Self.measuringHeight))
            window.layoutIfNeeded()
            if contentHeight <= 0 {
                let fits = hosting.sizeThatFits(in: NSSize(width: SettingsMetrics.contentWidth,
                                                           height: maxContentHeight))
                contentHeight = clamp(fits.height)
            }
            hasBeenPlaced = true
            window.setFrame(frame(forContentHeight: contentHeight), display: false)
            window.center()
        }
        applyDockPolicy(open: true)
        // An accessory (menu-bar) app is never brought forward by the cooperative `activate()`.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.windowVisible = true
        pageShown(selection.page)
    }

    // MARK: Height

    private var maxContentHeight: CGFloat {
        let screen = window.screen ?? NSScreen.main
        return max(200, (screen?.visibleFrame.height ?? 900) - Self.screenAllowance)
    }

    private func clamp(_ height: CGFloat) -> CGFloat {
        min(max(height.rounded(), 1), maxContentHeight)
    }

    private func pageReported(_ height: CGFloat) {
        let wanted = clamp(height)
        guard abs(wanted - contentHeight) > 0.5 else { return }
        contentHeight = wanted
        guard hasBeenPlaced else { return }
        scheduleResize()
    }

    /// On the next turn of the run loop, never inline: an animated `setFrame` does not return until the
    /// animation has run, and this is reached from inside a SwiftUI update. Coalesced.
    private func scheduleResize() {
        guard !resizePending else { return }
        resizePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizePending = false
            let target = self.frame(forContentHeight: self.contentHeight)
            guard target != self.window.frame else { return }
            self.window.setFrame(target, display: true, animate: self.window.isVisible)
        }
    }

    /// The frame that holds `height` points of content, keeping the top-left corner where it is. The
    /// chrome is measured from the live window: with a `.preference` toolbar the title bar and the
    /// toolbar are one band whose height is AppKit's business.
    private func frame(forContentHeight height: CGFloat) -> NSRect {
        let current = window.frame
        let content = window.contentView?.frame.size ?? current.size
        let chrome = NSSize(width: max(current.width - content.width, 0),
                            height: max(current.height - content.height, 0))
        var target = current
        target.size = NSSize(width: SettingsMetrics.contentWidth + chrome.width, height: height + chrome.height)
        target.origin.y = current.maxY - target.height
        return target
    }

    // MARK: The toolbar

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // After the toolbar is on the window, so the item it names already exists.
        toolbar.selectedItemIdentifier = identifier(for: selection.page)
    }

    private func identifier(for page: SettingsPageID) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(page.rawValue)
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsPageID.allCases.map(identifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    /// Every page, so that the one being shown is the one drawn as selected.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPageID(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.title
        item.paletteLabel = page.title
        item.image = image(for: page)
        item.target = self
        item.action = #selector(pagePicked(_:))
        return item
    }

    /// A symbol name this macOS does not know resolves to nil, and an item with no image is a gap
    /// nobody can aim at. The stand-in costs a wrong picture rather than an unreachable page.
    private func image(for page: SettingsPageID) -> NSImage? {
        if let image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title) {
            return image
        }
        Log.app.error("settings: no SF Symbol named \(page.symbol, privacy: .public); the \(page.title, privacy: .public) page shows a stand-in")
        return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: page.title)
    }

    @objc private func pagePicked(_ sender: NSToolbarItem) {
        guard let page = SettingsPageID(rawValue: sender.itemIdentifier.rawValue) else { return }
        selection.page = page
        window.title = page.title
        pageShown(page)
    }

    /// What a page reads when it comes into view, which the window does rather than the page: a view's
    /// `onAppear` does not fire again when this window, built once, is shown again on the same page.
    /// The hook files change when a button here is pressed and are read then too; the Health page's
    /// doctor and process readings are taken now and on Check Again, never on a timer.
    private func pageShown(_ page: SettingsPageID) {
        switch page {
        case .system: model.refreshHooks()
        case .health: model.readHealth()
        default: break
        }
    }

    // MARK: Going away

    /// An accessory app with no window left is still the active application, which would send the
    /// user's keystrokes nowhere. Miniaturising never fires `windowWillClose`, hence both.
    func windowWillClose(_ notification: Notification) {
        model.windowVisible = false
        // A Playground preview must not outlive the window that started it.
        model.stopPreview()
        model.hideTopic()
        applyDockPolicy(open: false)
        handBackActivation()
    }

    func windowDidMiniaturize(_ notification: Notification) { handBackActivation() }

    /// Unless another window of the app is up: the update window needs the app active to stay in
    /// front, and so does the onboarding wizard, which has no Dock icon to be fetched back from.
    private func handBackActivation() {
        if !UpdateController.shared.windowIsUp, !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: The Dock

    /// MySidepulse is a menu-bar app, but while this window is open it behaves like a regular one:
    /// a Dock icon, a ⌘-Tab entry, a main menu with Quit. That holds with the menu-bar item hidden
    /// too, which is when it matters most: the window is then the whole visible app.
    private func applyDockPolicy(open: Bool) {
        assertPolicy(open ? .regular : .accessory)
        // The accessory to regular transform occasionally does not take when the app is not
        // active (window open, Dock icon missing) while the in-process getter still claims it
        // did. NSRunningApplication is the LaunchServices view, the one the Dock actually renders,
        // so verify against that and re-assert whatever is currently wanted until the two agree.
        verifyPolicy(attemptsLeft: 3)
    }

    private func assertPolicy(_ policy: NSApplication.ActivationPolicy) {
        let accepted = NSApp.setActivationPolicy(policy)
        Log.app.notice("""
            dock policy: asked \(policy == .regular ? "regular" : "accessory", privacy: .public) \
            accepted=\(accepted) ls=\(NSRunningApplication.current.activationPolicy.rawValue)
            """)
        // Promoting an accessory to a regular app mid-flight can leave the
        // window behind other apps; re-activating settles focus.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private func verifyPolicy(attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let isOpen = self.window.isVisible
            let want: NSApplication.ActivationPolicy = isOpen ? .regular : .accessory
            guard NSRunningApplication.current.activationPolicy != want else { return }
            self.assertPolicy(want)
            self.verifyPolicy(attemptsLeft: attemptsLeft - 1)
        }
    }
}

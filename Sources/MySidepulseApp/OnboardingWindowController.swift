import AppKit
import MySidepulseCore
import MySidepulsePlatform

/// The wizard's numbers, short enough to read inside a layout.
private typealias M = OnboardingMetrics

// MARK: - The pages

/// A capsule on the first page: an SF Symbol and two or three words, in the brand colour.
struct OnboardingPill {
    let symbol: String
    let text: String
}

/// One page of the wizard. Order is the order the user walks them.
enum OnboardingPage {
    /// The app icon, a headline with one word accented, a short description, optional capsules,
    /// one button.
    case hero(title: String, accent: String?, body: String, pills: [OnboardingPill], button: String)
    /// A page of rows. `advanceWhen` decides whether its button reads "Continue" or "Skip".
    case list(header: String, intro: String, items: [GrantItem],
              advanceWhen: ([GrantItem]) -> Bool)
    /// The last page. Its button finishes and closes the window.
    case final(title: String, body: String, button: String)

    /// The window's height while this page is shown.
    var height: CGFloat {
        switch self {
        case .hero: OnboardingMetrics.heroHeight
        case .list: OnboardingMetrics.listHeight
        case .final: OnboardingMetrics.finalHeight
        }
    }
}

/// The list page's rule: every required row is done.
private func everyRequiredGrant(_ items: [GrantItem]) -> Bool {
    items.filter(\.required).allSatisfy { $0.granted() }
}

// MARK: - The window

/// Three pages: the pitch, everything MySidepulse needs to be set up, and "All set".
///
/// **An ordinary window.** The normal level, the default collection behaviour. It comes up in
/// front because it is the last window to open, and from then on it takes its turn like any other:
/// a permission prompt and System Settings both open over it and stay there until the user leaves
/// them. It belongs to the Space it opened in and keeps its place there across a Space switch. The
/// app is activated once, when the window opens.
///
/// **It stays an accessory window**, unlike `SettingsWindow`, which promotes the app to `.regular`
/// while it is open. That promotion re-activates the app, which is exactly what must not happen
/// while System Settings is in front. The main menu the window needs for ⌘W and ⌘C is built at
/// launch by `AppDelegate`, so nothing is missing.
///
/// **Two things bring it back**, both of them a flow ending, and nothing else: `returnsFocus` for
/// a flow that owned a modal dialog, and `mayOpen` for a flow that sent the user to another app,
/// through `FocusReturnWatch`.
///
/// **No prompt is ever shown unless the user clicked for it.** Nothing here, and nothing in the
/// app's start-up path, calls a request API; only a row's button does.
///
/// **Nothing tells an app that a grant was made in System Settings**, so the list page re-reads its
/// rows every `OnboardingMetrics.pollInterval` while the window is up. A page is built only on a
/// change of step: a grant that moves redraws the one row it belongs to.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    /// The app's own working red, the same value `SettingsSupport` gives `.working`: the wizard and
    /// the strip replica accent with one colour.
    private static let brand = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.30, alpha: 1)

    private let pages: [OnboardingPage]
    /// Pressed on the last page. Records that onboarding is done.
    private let onFinish: () -> Void
    /// Whether another window of the app still needs it active once the wizard goes away.
    /// Injected, never inferred from `NSApp.windows`: an accessory app with no window left is
    /// still the active application, which would send the user's keystrokes nowhere.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    private var step = 0
    private var observers: [NSObjectProtocol] = []
    /// The rows of the page on screen, by grant. A grant that moves updates its own row and
    /// nothing else: rebuilding the page to show it blanks the window and draws it again.
    private var rows: [OnboardingGrant: GrantRow] = [:]
    /// The page's primary button, whose title follows whether the page's rule is met. Weak: the
    /// page that owns it is thrown away on a change of step.
    private weak var primaryButton: NSButton?
    private var poll: Timer?
    /// Brings the wizard back when the app a row's button sent the user to quits.
    private let focusReturn = FocusReturnWatch()

    init(model: SettingsModel, onFinish: @escaping () -> Void) {
        let t = Loc.onboarding
        self.onFinish = onFinish
        self.pages = [
            .hero(title: t.heroTitle, accent: t.heroAccent, body: t.heroBody,
                  pills: [OnboardingPill(symbol: "waveform", text: t.pillWorking),
                          OnboardingPill(symbol: "checkmark.circle", text: t.pillFinished),
                          OnboardingPill(symbol: "bell.badge", text: t.pillNeedsYou)],
                  button: t.continueButton),
            .list(header: t.setupHeader, intro: t.setupIntro,
                  items: OnboardingCatalog.items(model: model), advanceWhen: everyRequiredGrant),
            .final(title: t.finalTitle, body: t.finalBody, button: t.finishButton),
        ]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingMetrics.windowWidth,
                                height: OnboardingMetrics.heroHeight),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MySidepulse"
        window.center()
        window.isReleasedWhenClosed = false
        // Nothing else. No `level`, and no `collectionBehavior`: both are what make this window
        // cover the pane it just opened, or sink behind the user's terminal after a Space switch.
        window.contentView = NSView()
        super.init(window: window)
        window.delegate = self
        // Coming back from System Settings: re-read the rows. The poll covers a window that is
        // already key and so never sees this edge.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshGrants() } })
        // The app coming forward brings the wizard with it, the way any app's window does.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.comeForward() } })
        refreshGrants()
        render()
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    deinit {
        poll?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startPolling()
    }

    /// The wizard back in front of the app's own windows, and only while it is the app's one
    /// window, so it never lands on top of Settings or the update window. Ordering front, never
    /// `NSApp.activate(ignoringOtherApps:)`: that is what pulls the wizard over the System
    /// Settings window it has just opened.
    private func comeForward() {
        guard let window, window.isVisible, !othersNeedUsActive() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        focusReturn.stop()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: Building a page

    /// Builds the page for `step`. Called on a change of step and nowhere else: a grant that
    /// moves, a flow that starts or ends, and a poll tick all change one row, never the page.
    private func render() {
        guard let window, let content = window.contentView, pages.indices.contains(step) else {
            return
        }
        rows.removeAll()
        primaryButton = nil
        content.subviews.forEach { $0.removeFromSuperview() }

        let page = pages[step]
        let view: NSView
        switch page {
        case let .hero(title, accent, body, pills, button):
            view = hero(title: title, accent: accent, body: body, pills: pills, button: button)
        case let .list(header, intro, items, advanceWhen):
            view = listPage(header: header, intro: intro, items: items, advanceWhen: advanceWhen)
        case let .final(title, body, button):
            view = hero(title: title, accent: nil, body: body, pills: [], button: button)
        }

        // Grow downward from a fixed title bar.
        var frame = window.frame
        let dy = page.height - content.frame.height
        frame.origin.y -= dy
        frame.size.height += dy
        window.setFrame(frame, display: true, animate: window.isVisible)

        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func hero(title: String, accent: String?, body: String, pills: [OnboardingPill],
                      button: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.heightAnchor.constraint(equalToConstant: M.heroIcon).isActive = true

        let headline = NSTextField(wrappingLabelWithString: "")
        // A selectable label enters the field editor on a click and loses its attributes.
        headline.isSelectable = false
        headline.allowsEditingTextAttributes = true
        headline.font = .systemFont(ofSize: M.heroTitle, weight: .bold)
        headline.alignment = .center
        headline.attributedStringValue = Self.accented(title, word: accent)
        headline.preferredMaxLayoutWidth = M.heroTextWidth
        headline.widthAnchor.constraint(lessThanOrEqualToConstant: M.heroTextWidth).isActive = true

        let description = NSTextField(wrappingLabelWithString: body)
        description.isSelectable = false
        description.font = .systemFont(ofSize: M.heroBody)
        description.alignment = .center
        description.preferredMaxLayoutWidth = M.heroTextWidth
        description.textColor = .secondaryLabelColor

        var extras: [NSView] = []
        if !pills.isEmpty {
            let row = NSStackView()
            row.spacing = 8
            pills.forEach { row.addArrangedSubview(Self.pill($0)) }
            row.widthAnchor.constraint(lessThanOrEqualToConstant: M.pillRowWidth).isActive = true
            extras = [row]
        }

        let next = NSButton(title: button, target: nil, action: nil)
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.actionHandler = { [weak self] in MainActor.assumeIsolated { self?.advance() } }

        let stack = NSStackView(views: [icon, headline, description] + extras + [next])
        stack.orientation = .vertical
        stack.spacing = M.heroSpacing
        stack.setCustomSpacing(M.heroTitleToBody, after: headline)
        stack.edgeInsets = M.heroInsets
        return stack
    }

    private func listPage(header: String, intro: String, items: [GrantItem],
                          advanceWhen: @escaping ([GrantItem]) -> Bool) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: M.listTitle, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.font = .systemFont(ofSize: M.listIntro)
        introLabel.textColor = .secondaryLabelColor
        introLabel.preferredMaxLayoutWidth = M.listIntroWidth

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = M.listRowSpacing
        list.alignment = .leading
        for (index, item) in items.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let row = GrantRow(item: item,
                               window: { [weak self] in self?.window },
                               focusReturn: focusReturn,
                               didFinish: { [weak self] in self?.updatePrimaryButton() })
            rows[item.id] = row
            list.addArrangedSubview(row.view)
        }
        list.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let primary = NSButton(title: "", target: nil, action: nil)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.actionHandler = { [weak self] in MainActor.assumeIsolated { self?.advance() } }
        primaryButton = primary
        // The footer is a plain view with the button pinned to its trailing edge and to **both** its top
        // and bottom, which fixes the footer's height to the button's. An `NSStackView` holding an invisible
        // spacer is the trap: a spacer has no intrinsic height, so nothing decides the footer's height and
        // the vertical stack hands it every point of slack the page is not using. Granting a permission swaps
        // a row's 26 pt button for an 18 pt label, the list shrinks, the footer grows to absorb it, and the
        // button sits wherever the slack put it: still drawn, `AXFrame` still plausible, no constraint broken,
        // and a press on it does not land.
        let footer = NSView()
        primary.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(primary)
        NSLayoutConstraint.activate([
            primary.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            primary.topAnchor.constraint(equalTo: footer.topAnchor),
            primary.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])

        // The slack goes here, deliberately, and into nothing else: above the footer, so the stepping button
        // stays at the bottom right of the page however tall the rows happen to be.
        let slack = NSView()
        slack.setContentHuggingPriority(.init(1), for: .vertical)
        slack.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let stack = NSStackView(views: [headerLabel, introLabel, list, slack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = M.listSpacing
        stack.setCustomSpacing(M.listIntroToList, after: introLabel)
        stack.setCustomSpacing(M.listToFooter, after: list)
        stack.edgeInsets = M.listInsets
        // Width constraints only once every view shares the stack as an ancestor.
        list.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -M.listSideInset).isActive = true
        footer.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        updatePrimaryButton()
        return stack
    }

    /// "Continue" once the page's rule is met, "Skip" until then. Set in place, so the page is
    /// never rebuilt for a word.
    private func updatePrimaryButton() {
        guard let primaryButton, pages.indices.contains(step),
              case let .list(_, _, items, advanceWhen) = pages[step] else { return }
        let t = Loc.onboarding
        let title = advanceWhen(items) ? t.continueButton : t.skipButton
        if primaryButton.title != title { primaryButton.title = title }
    }

    // MARK: Following the system

    /// Re-reads every row and lets each redraw itself if its own state moved. Notification
    /// authorization is asynchronous, so the read goes through `refreshNotifications` and the rows
    /// are asked in its callback, once the cached value is current. A page with no rows has
    /// nothing to do here.
    private func refreshGrants() {
        OnboardingCatalog.refreshNotifications { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for row in self.rows.values { row.refresh() }
                self.updatePrimaryButton()
            }
        }
    }

    /// Idempotent.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: OnboardingMetrics.pollInterval,
                                    repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGrants() }
        }
    }

    /// Idempotent.
    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func advance() {
        if step < pages.count - 1 {
            step += 1
            render()
        } else {
            onFinish()
            close()
        }
    }

    // MARK: Drawing

    /// A rounded capsule with an SF Symbol and a short label, in the brand colour.
    private static func pill(_ pill: OnboardingPill) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: pill.symbol,
                                               accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!)
        image.contentTintColor = brand
        image.symbolConfiguration = .init(pointSize: M.pillSymbol, weight: .semibold)
        let label = NSTextField(labelWithString: pill.text)
        label.font = .systemFont(ofSize: M.pillLabel, weight: .medium)
        label.textColor = brand
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, label])
        row.spacing = M.pillSpacing
        row.edgeInsets = M.pillInsets
        row.wantsLayer = true
        row.layer?.backgroundColor = brand.withAlphaComponent(M.pillTint).cgColor
        row.layer?.cornerRadius = M.pillRadius
        return row
    }

    /// The headline, with `word` in the brand colour where it occurs. `word` is localized
    /// separately, so a translation accents its own word and not a fragment of another.
    private static func accented(_ text: String, word: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: OnboardingMetrics.heroTitle,
                                                  weight: .bold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        if let word, let range = text.range(of: word, options: .caseInsensitive) {
            string.addAttribute(.foregroundColor, value: brand, range: NSRange(range, in: text))
        }
        return string
    }
}

// MARK: - The row

/// One row of the list page: what it is, why it is wanted, and a trailing control that follows its
/// state. **Built once and updated in place.** Rebuilding the page to show a grant that moved
/// empties the window and draws it again, which reads as a blink and a reload on every press and
/// every poll tick.
///
/// While a flow is running the row keeps the button that started it, disabled, with a spinner
/// beside it, and the poll leaves that loading state alone until the flow reports back. A flow that
/// reports more than once settles the row on the first only.
@MainActor
private final class GrantRow {
    let view: NSStackView

    /// What the trailing control is showing. Compared before redrawing, so a refresh that changes
    /// nothing touches no view at all.
    private enum Shown: Equatable { case nothing, granted, notGranted, busy(String) }

    private let item: GrantItem
    private let window: () -> NSWindow?
    private let focusReturn: FocusReturnWatch
    /// Called once a flow has reported back: the page's primary button may have to change with it.
    private let didFinish: () -> Void
    private let trailing = NSView()
    private var shown: Shown = .nothing
    private var busy = false

    init(item: GrantItem, window: @escaping () -> NSWindow?, focusReturn: FocusReturnWatch,
         didFinish: @escaping () -> Void) {
        self.item = item
        self.window = window
        self.focusReturn = focusReturn
        self.didFinish = didFinish

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: M.rowTitle, weight: .semibold)
        let titleRow = NSStackView(views: [title])
        titleRow.spacing = 6
        if item.required, let mark = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                             accessibilityDescription: Loc.onboarding.required) {
            let warn = NSImageView(image: mark)
            warn.contentTintColor = .systemOrange
            warn.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            warn.toolTip = Loc.onboarding.required
            titleRow.addArrangedSubview(warn)
        }
        let why = NSTextField(wrappingLabelWithString: item.why)
        why.font = .systemFont(ofSize: M.rowWhy)
        why.textColor = .secondaryLabelColor
        why.preferredMaxLayoutWidth = M.rowTextWidth
        let text = NSStackView(views: [titleRow, why])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.widthAnchor.constraint(lessThanOrEqualToConstant: M.rowTextWidth).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = NSStackView(views: [text, spacer, trailing])
        view.alignment = .centerY
        view.spacing = 12
        refresh()
    }

    /// Re-reads the state and redraws the trailing control only if it should look different. A row
    /// whose flow is still running keeps its loading state: the poll must not take it away.
    func refresh() {
        guard !busy else { return }
        show(item.granted() ? .granted : .notGranted)
    }

    private func show(_ next: Shown) {
        guard next != shown else { return }
        shown = next
        trailing.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch next {
        case .nothing:
            content = NSView()
        case .busy(let title):
            let button = Self.button(title)
            button.isEnabled = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            let pair = NSStackView(views: [spinner, button])
            pair.spacing = 8
            content = pair
        case .granted:
            let done = NSTextField(labelWithString: item.doneTitle)
            done.font = .systemFont(ofSize: OnboardingMetrics.rowTrailing)
            done.textColor = .secondaryLabelColor
            if let remove = item.remove {
                let title = item.removeTitle ?? Loc.onboarding.removeButton
                let button = Self.button(title)
                button.actionHandler = { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.start(title) { settle in remove(self.window(), settle) }
                    }
                }
                let pair = NSStackView(views: [done, button])
                pair.spacing = 8
                content = pair
            } else {
                content = done
            }
        case .notGranted:
            let button = Self.button(item.buttonTitle)
            button.actionHandler = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.start(self.item.buttonTitle) { settle in
                        self.item.action(self.window(), settle)
                    }
                }
            }
            content = button
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            content.topAnchor.constraint(equalTo: trailing.topAnchor),
            content.bottomAnchor.constraint(equalTo: trailing.bottomAnchor),
        ])
    }

    /// Runs one flow with the row in its loading state, reads the state again when it reports
    /// back, and settles who is in front. The order matters: the row is right before anything is
    /// activated.
    private func start(_ title: String, _ flow: (_ settle: @escaping () -> Void) -> Void) {
        busy = true
        show(.busy(title))
        var settled = false
        flow { [weak self] in
            MainActor.assumeIsolated {
                guard !settled else { return }
                settled = true
                guard let self else { return }
                self.busy = false
                self.refresh()
                self.didFinish()
                self.item.reclaimFocusIfNeeded(self.window())
                if let opened = self.item.mayOpen {
                    self.focusReturn.whenQuit(opened, bringBack: self.window())
                }
            }
        }
    }

    private static func button(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        return button
    }
}

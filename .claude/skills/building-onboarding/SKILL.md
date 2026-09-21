---
name: building-onboarding
description: Use when building, changing or reviewing MySidepulse's first-run onboarding wizard, or any window that asks the user for macOS permissions (Notifications, Login Items, a launch agent) or walks them through setting the app up - adding a page, adding or rewording a row, changing what a grant button does, or fixing a window that covers System Settings, sinks behind other apps, blinks, or shows a stale grant.
---

# Building onboarding

Origin: `/Users/Rubens/Projects/koffeelid/.claude/skills/building-onboarding`. A rule the owner changes
there is changed here too.

Sibling of `building-settings-pages`, and it assumes that skill's ten rules for words. Read this one whole
before the first edit: most of it is traps, and every one of them shipped at least once.

**The shape.** A titled, closable, fixed-width window that steps through pages with one button at the
bottom right. First a **hero** page: the app icon, a headline with one word accented, two or three lines of
description, optional capsules. Then one **list** page per set of things the user has to grant or set up:
a header, one grey paragraph, rows, and the stepping button. Optional extra list or hero pages between.
Last a **final** hero page whose button finishes and closes.

| You are in | Do this |
|---|---|
| **MySidepulse** | The window exists: `Sources/MySidepulseApp/OnboardingWindowController.swift`, `OnboardingCatalog.swift`, `ControlActionHandler.swift`, with the words in `Sources/MySidepulseCore/StringsOnboarding.swift`. Change it there. This file is the contract it keeps. |
| **A new app** | Copy `reference/OnboardingWindow.swift`, `reference/GrantRow.swift` and `reference/ControlActionHandler.swift` as they are (all three parse alone), edit the places marked `EDIT`, and write the grant catalogue. |

## The one thing agents get wrong

A fresh agent, given this exact task and no skill, produced a window that was right about the level and
wrong about everything that made this window painful. It is worth knowing what it chose, because you will
be tempted by the same three things, and it justified all of them:

| It wrote | It said | Why it is wrong |
|---|---|---|
| Row titled `"Login Items"` | "deliberately mirrors the System Settings section name" | That is the **pane**. The switch is called *Background App Activity*, and the pane also holds *Open at Login*, where the app appears too. The user reads the row, opens the pane, and cannot tell which of the two to touch. |
| `if !CGRequestScreenCaptureAccess() { open(settingsURL) }` | "the app does not just show failure" | The return value is the state **at the moment of the call**, still not-granted while the prompt is on screen. So this opens the pane every single time: the user gets the dialog *and* System Settings, one over the other. |
| `didBecomeActive` instead of a timer | "to avoid needless work on every focus change" | An accessory app is not activated when the user closes System Settings. The notification never fires, the grant never appears, and the window never comes back. |

## The window

```swift
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
w.title = <app name>; w.center(); w.isReleasedWhenClosed = false
w.contentView = NSView()
```

**That is the whole window.** Everything else that has ever been set on it was a bug:

| Never set | Why |
|---|---|
| `level = .floating` | Above **every** app, including the System Settings window and the administrator dialog the wizard's own buttons open. It covers its own instructions. |
| `collectionBehavior` | `.moveToActiveSpace` drags the window between Spaces and re-inserts it at the **back** of the new Space's window list, so a Space switch and back leaves it behind the user's terminal. `.fullScreenAuxiliary` lets it sit over a full-screen app. A normal window belongs to one Space and keeps its place in it. |
| `.miniaturizable` | An accessory app has no Dock icon to restore from. A miniaturised wizard is a lost wizard. |
| `.resizable` | The height is the page's, set by the code. |

**The app is activated once, when the window opens** (`NSApp.activate(ignoringOtherApps: true)` beside
`showWindow`), and that is the only unconditional activation in the feature. It is in front because it is
the last window to open, and from then on it takes its turn.

**MySidepulse's wizard stays an accessory window**, and that is a deliberate difference from its own
Settings window. `SettingsWindow` promotes the app to `.regular` while it is open, so that window gets a
Dock icon and a ⌘-Tab entry; the wizard does not, because it is a wizard and because the promotion
re-activates the app, which is precisely what must not happen while System Settings is in front. The main
menu the window needs for ⌘W and ⌘C is already built at launch by `AppDelegate.buildMainMenu`, so nothing
is missing.

## Who is in front

This is the hard part and it has four cases. Get them from the table, not from instinct.

| The moment | What the window does | Why |
|---|---|---|
| A grant button opens System Settings, or a system prompt's own button does | **Nothing.** Stay where you are. | The flow reports back immediately, while System Settings is still coming up. Activating here is what put the wizard on top of the pane it had just opened. |
| The app the button sent the user to **quits** | Come back to the front: activate and order front | macOS gives an ordinary app the front back here and **skips `LSUIElement` apps**. `GrantItem.mayOpen` + `FocusReturnWatch`. |
| A dialog of the app's own is answered (administrator password) | Come back to the front | A modal drawn by another process blocks the main thread; when it closes an accessory app is not reactivated. `GrantItem.returnsFocus`. |
| The app becomes active for any other reason | Order front **only if no other window of the app is up** | Otherwise the wizard lands on top of the Settings window the user just asked for. Order front; never `activate(ignoringOtherApps:)`. |

**`mayOpen` is set on every macOS grant, not only the ones whose button opens a pane.** A system permission
dialog carries its own button to System Settings, so any of these rows can be the reason the user ends up
there, and the window has to come back when they close it. Leave it nil only for a flow that stays inside
the app: in MySidepulse that is the Claude Code hooks, the terminal hook, Startup and Phone alerts, and
only Notifications sets it.

`othersNeedUsActive` is injected, never inferred from `NSApp.windows`, and it does two jobs: it gates that
last case, and on `windowWillClose` it decides whether to `NSApp.deactivate()` — an accessory app with no
window left is still the active application, which sends the user's keystrokes nowhere. **It is wired both
ways**: the wizard asks whether Settings or the update window is up, `SettingsWindow` and
`UpdateController` ask whether the wizard is up. A one-way wiring hands activation back while a window of
the app is still on screen.

**There is no flag for the second case.** The only alternative is `setActivationPolicy(.regular)` while the
window is up, which gives the app a Dock icon and re-activates it. Do not reach for it without deciding
that with the owner.

## Naming a grant

**A row's title is exactly what System Settings calls the switch, quoted from the system's own strings.**
Not the pane it lives in. Not the API. Not the name macOS used two releases ago. The user has to find it in
a list, so a name of the app's own is a dead end however well it reads. A row for something the app does
itself takes the app's own name for it, and then it must read the same as the Settings window's own row for
the same thing: MySidepulse's `Startup` row is the General page's Startup group, not a second name for it.

Never write a system name from memory. Look it up, every time:

```bash
# The pane's own strings, both languages. Login Items, Privacy & Security, wherever the switch lives.
ls /System/Library/ExtensionKit/Extensions | grep -i -E 'login|privacy|security|notification'
F=/System/Library/ExtensionKit/Extensions/LoginItems.appex/Contents/Resources/Localizable.loctable
plutil -extract en xml1 -o - "$F" | grep -i -B1 -A1 'background\|login'
plutil -extract fr xml1 -o - "$F" | grep -i -B1 -A1 'arrière-plan'
```

As of macOS 27, for an app that calls these APIs:

| The app calls | The row is titled | French |
|---|---|---|
| `SMAppService.agent(...).register()` | Background App Activity | Activité des apps en arrière-plan |
| `UNUserNotificationCenter.requestAuthorization` | Notifications | Notifications |
| `CGRequestScreenCaptureAccess` | Screen Recording | Enregistrement de l'écran |
| `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | Input Monitoring | Surveillance de l'entrée |
| a `launchctl bootstrap`ped plist, a hook in someone else's file, anything of the app's own | the app's own name for it | there is no system switch to match |

**Two traps inside the lookup itself.**

1. A pane holds several switches. Login Items shows *Open at Login* **and** *Background App Activity*, and a
   bundled agent puts the app in both lists. Naming the row after the pane tells the user nothing.
2. A loctable keeps retired names. Privacy & Security still ships `SCREEN_CAPTURE` ("Screen Recording")
   **and** `SCREENANDAUDIOCAPTURE` ("Screen & System Audio Recording") because they are two separate grants.
   **The API the app calls decides which**, not a guess about which key the pane reads.

Every name goes in both languages, through `Loc.onboarding`, with the OS's own punctuation (macOS writes a
curly apostrophe: `Surveillance de l'entrée`).

## Never ask for a permission on your own

**Every permission prompt the user ever sees comes from a click of theirs, and there is no exception.**
Not at launch. Not when a window opens. Not when a feature that needs the grant is switched on. Not "once,
to get it out of the way". A prompt the user did not ask for arrives with no explanation beside it, and a
refusal is remembered by macOS for good: an unprompted ask is how an app loses a grant permanently.

This rule cost MySidepulse a written one: `docs/functional.md` §12 used to say the Notifications permission
was "asked for the first time there is [a newer release]", so an automatic update check could prompt out of
nowhere. The owner overruled it on 2026-09-21. `UpdateNotifier` now **reads** the authorization and posts
only if it is already there; the wizard's Notifications row is the only thing that asks.

Two ways this rule gets broken, and the second is not obvious:

1. **Requesting at startup.** A line in the app's start-up path that calls a request API, often guarded by
   something like "only once onboarding is done". If the user reached the end of onboarding without granting
   that row, the grant is still `notDetermined`, and the next launch prompts them out of nowhere.
2. **Reading state with a request API.** A request API returns the current state, so it is tempting as the
   reader. It also prompts. Behind a 2 s poll that is a prompt every two seconds.

So each grant has **two** separate calls, and they are never the same one:

| Job | Use | Never |
|---|---|---|
| read, on every poll tick | `getNotificationSettings`, `CGPreflightScreenCaptureAccess()`, `IOHIDCheckAccess(...)`, `SMAppService...status` | any `request`/`Request` call |
| ask, from a button only | `requestAuthorization(...)`, `CGRequestScreenCaptureAccess()`, `IOHIDRequestAccess(...)`, `register()` | anywhere but a control's action |

`GrantItem.granted` is a reader and nothing else. If the only API a framework offers to read a grant is one
that also asks, the row shows "unknown" and offers its button; it does not call it to find out.

`UNUserNotificationCenter.current()` **traps in a process with no bundle** (a binary run out of `.build`),
so nothing touches it unless `Bundle.main.bundleURL.pathExtension == "app"`. `UpdateNotifier` has the same
guard; the catalogue keeps its own.

## What a grant button does

**It asks macOS, and it does nothing else** — and a button is the only thing in the whole app that may ask.
The system dialog carries its own button to the right pane, so the app never opens a pane beside it, and
never instead of it once the grant has been refused.

```swift
action: { _, done in Notifications.request(done) }                       // right
action: { _, done in if !request() { openSystemSettings() }; done() }    // the double-open bug
```

The one exception is a grant macOS offers **no dialog for**, where the pane *is* the flow (Login Items is
the only one today), and the button then says what it does: "Open Login Items Settings".

A row whose flow stays inside the app does that flow and nothing else: MySidepulse's hook rows go through
`SettingsModel`, so the wizard and the Settings window install hooks by one implementation, with one log
line and one error path. **Reads go straight to `HookInstaller`** — `granted` runs on every poll tick and
must not publish into SwiftUI.

Consequences to accept rather than work around:

- A request API's result is the state **now**, never the user's answer. Never branch on it.
- Once a grant is explicitly denied, macOS shows nothing and the call returns the denial, so the button does
  nothing visible. That is the cost of the rule. Do not "fix" it by relabelling the button to *Open
  Settings…* on a second press: that reintroduces the second path.
- Call these APIs on the main thread. They return at once; they do not block on the prompt.

Every flow calls `done` on the main thread, always, including when it could do nothing.

## Following the system, without blinking

Nothing tells an app that a grant was made in System Settings. So:

- **Poll every 2 s while the window is up**, started in `showWindow` and stopped in `windowWillClose`.
  `didBecomeKeyNotification` is kept as well, but it cannot be the only signal: a window that is already key
  never sees that edge, and an accessory app is often never activated at all.
- **A page is built on a change of step and at no other time.** A grant that moves redraws the one row it
  belongs to. Rebuilding the page empties the content view and the replacement only lands at the next layout
  pass, which reads as a blink and a reload — on every press and every tick. Comparing state first and
  rebuilding "only when something moved" does not help: the flicker is the rebuild.
- **A row owns its trailing control** and swaps that alone, after comparing what it shows with what it should
  show, so a tick that changes nothing touches no view.
- **The stepping button's title is set in place**, never by rebuilding the page for a word.

**The loading state.** While a flow runs the row keeps the button that started it, **disabled, with a small
spinner beside it** — not hidden, not replaced. The poll must leave a busy row alone, or the next tick takes
the spinner away underneath the user. A flow that reports more than once settles the row on the first only.

## The pages

Numbers live in `Metrics` in `reference/GrantRow.swift` and in `OnboardingMetrics` in the live
`OnboardingCatalog.swift`. They were fitted by eye. Reproduce them; you cannot see the window, so do not
retune one because it reads better in a diff.

- **Hero**: icon 104, headline 26 bold centred with one word in the brand colour, body 14 secondary, text
  wraps at 440, capsules optional, insets 32/40/36/40, spacing 18 with 10 after the headline.
- **List**: header 22 bold, one grey paragraph at 13 wrapping at 460, rows 12 apart with a separator
  between, insets 28/40, 20 after the intro and 24 before the footer, list width the page less 80.
- **Row**: title 14 semibold, an orange `exclamationmark.triangle.fill` after it when required, why 12
  secondary wrapping at 320, trailing control at the trailing edge.
- **Heights**: hero 440, list 560, final 400. The window resizes around its **top-left** corner, so the
  title bar stays put and the page grows downward.
- The accent word is localized **separately** from the headline, so a translation accents its own word.
- The stepping button is `keyEquivalent = "\r"`, reads **Continue** once the page's rule is met and **Skip**
  until then. The permissions page's rule is every **required** grant; an optional page's is any one row.

**MySidepulse walks three pages, not four**: the pitch, one list page holding every row, and "All set". The
owner chose that on 2026-09-21 over two list pages, because the app has only five rows in all and two of
them are macOS grants. The brand colour is the app's own working red, `NSColor(srgbRed: 1.0, green: 0.33,
blue: 0.30, alpha: 1)` — the same value `SettingsSupport.screenColor` gives `.working`, so the wizard and
the strip replica agree.

## The footer, and where the slack goes

**This one shipped in three of these apps at once, and it is the worst failure the window has had**: the
stepping button drawn at the bottom right of a list page, looking perfectly normal, and unclickable for
ever. It started the moment a permission was granted.

```swift
let spacer = NSView()
spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
let footer = NSStackView(views: [spacer, primary])      // the bug
```

A bare `NSView` has no intrinsic size, so **nothing decides that footer's height**, and the enclosing
vertical stack hands it every point the page is not using. Granting a permission swaps a row's 26 pt button
for an 18 pt "Granted" label, the list shrinks by 36 pt, and the slack goes into the footer:

```
before the swap   footer bounds 460 x 24     button frame (381, 0,  79, 24)
after the swap    footer bounds 460 x 186    button frame (381, 81, 79, 24)
```

The button is still inside the footer, so **no constraint breaks and `AXFrame` keeps naming a plausible
rectangle**. `AXPress` on it works. Every other element of the page hit-tests correctly. It has simply
stopped being where the page put it, and a press on it does not land.

**What holds.** A footer is a plain `NSView` with the button pinned to its trailing edge **and to both its
top and bottom**, which fixes the footer's height to the button's. The slack is then given somewhere on
purpose, a view of its own between the list and the footer, with vertical hugging and compression resistance
at **priority 1**, so no control can ever take it. `reference/OnboardingWindow.swift` has it.

**The rule behind it: `Metrics` decides sizes, and a stack view left free to decide one will.** Anywhere a
vertical stack holds a control beside something that can grow or shrink, ask which view absorbs the
difference, and answer it in the code rather than leaving it to Auto Layout.

**How to see it.** A frame that names a rectangle and a hit test that finds nothing there is this class of
bug, and only a real hit test shows it: the project's Accessibility probe prints the front window's subtree
with every element's frame, and asks what a hit test actually finds at a point. The window logs it too: the
`onboarding` category at `--level debug` prints the stepping button's frame in window coordinates and, up the
chain, each superview's height and whether it still contains it. Keep both.

- [ ] **The walk that catches it**: on a list page, with the permission not yet granted, press the stepping
      button: it advances. Go back, grant the permission, and press it again **without closing the window**.
      It must advance on the first click. A button that does nothing here is this bug, whatever it looks like.

## Wiring it into the app

- A **fresh controller every time** it is shown, so the pages re-read every grant and start at page one.
- `applicationShouldHandleReopen` prefers the wizard over the Settings window while it is up: with no Dock
  icon, `open -b <bundle id>` is how the user fetches it back.
- The last page's button records that onboarding is done, then closes. A window closed **before** that keeps
  the flag false, so the wizard returns at the next launch. Decide that deliberately.
- **A launch nobody asked for shows no wizard.** MySidepulse already knows which launches those are: a
  `QuietLaunch` marker (`make install`, the update helper) or an unread install outcome. The wizard is
  shown only when neither holds, so a reinstall over a configured Mac is silent and a drag install from the
  disk image is not.
- The flag is `AppConfig.onboardingDone`, and like **every** key added after the first release it is
  optional: a non-optional one fails the whole decode and resets the config, ntfy topic included.
  `Engine` owns the live config, so the wizard finishes through `Engine.markOnboardingDone()` and never
  writes `config.json` beside it.
- `Settings > System` gets a "Show Onboarding Again" button, reached through `SettingsModel.showOnboarding`,
  which `AppDelegate` sets.
- A grant catalogue is **one list**. MySidepulse's Settings window keeps its own rows for the two hook
  groups, because its pages are SwiftUI and the wizard is AppKit; what is shared is the **flow**, through
  `SettingsModel`. If a third surface ever needs the same rows, share the catalogue rather than the flow.

## Verify

```sh
swiftc -parse .claude/skills/building-onboarding/reference/*.swift   # they must parse alone
swift build
swift test                                                          # read BOTH summary lines
rg -n 'level *=|collectionBehavior' Sources/MySidepulseApp/Onboarding*.swift          # nothing
rg -n 'activate\(ignoringOtherApps' Sources/MySidepulseApp/Onboarding*.swift          # only where the table above allows it
rg -n 'requestAuthorization' Sources/MySidepulseApp                                    # only inside a row's action
rg -n '[—–‒―‐‑−]' Sources/MySidepulseCore/StringsOnboarding.swift                      # nothing
```

`LocalizationTests` reads `Sources/MySidepulseCore/Strings*.swift` off disk, so a sentence added there is
checked for both languages and for the long dash without being listed in a test.

Then walk it on hardware, because none of this has an automated test:

- [ ] The window opens in front. Click another app's window: it goes behind and **stays** there.
- [ ] Switch to another Space and back: still in front of what it was in front of.
- [ ] Press a grant button: **only** the system dialog, never System Settings alongside. Same on a second
      press after refusing once.
- [ ] Reach the last page having granted nothing, finish, then quit and launch again, twice: **no prompt
      appears by itself**, at launch or while the window sits open. Every prompt in the walk followed a click.
- [ ] Press a button that opens System Settings: the pane comes forward and **stays**. Grant it, leave the
      pane open: the row ticks over on its own within about 2 s, with the wizard still behind.
- [ ] Close the System Settings window: the wizard comes back in front of what it was in front of. Leave it
      open and click another app instead: the wizard does not move.
- [ ] No page rebuild: on every press and every tick, only one row's trailing control changes. The header
      and the other rows do not move.
- [ ] Every row's title matches a heading in the pane its button opens, word for word, or the Settings
      window's own name for the same thing.
- [ ] `open -b io.mysidepulse.app` brings the wizard forward, not Settings. With Settings also open,
      activating the app brings Settings forward, not the wizard.
- [ ] Closing the wizard gives the front back to whoever had it; keystrokes go to that app. With Settings
      still open, the app stays active.
- [ ] `make install` over a configured Mac opens **no** wizard and no Settings window.

## Red flags

| You are about to | Instead |
|---|---|
| Raise the level, or set a collection behaviour, so the window is easier to find | Reachability is a different problem from z-order. Use `applicationShouldHandleReopen`, ordering front when alone, and the poll. |
| Promote the app to `.regular` while the wizard is up, as `SettingsWindow` does | That re-activates the app, which is the bug. The wizard stays accessory; the main menu is already there. |
| Open System Settings because a request API returned false | It returns the state now, not an answer. Ask, and stop. |
| Relabel a button to *Open Settings…* after a refusal | Same second path, one press later. |
| Name a row after the pane, the API, or what you remember macOS calling it | Quote the switch from the system's loctable, in both languages. |
| Write a sentence in the window's own file | Every string is an accessor in `StringsOnboarding.swift` answering for every `Language`. |
| Rebuild the page to show a grant that moved | Redraw that row's trailing control. |
| Drive the refresh from `didBecomeActive` alone | An accessory app is often never activated. Poll. |
| Hide the button while its flow runs | Disable it and put a spinner beside it, so nothing jumps. |
| Ask for a grant at launch, or when a feature needing it is switched on | Only a click asks. Report the missing grant and offer the button. |
| Read a grant with the API that requests it | Preflight and check APIs read; request APIs ask. Behind the poll, the second prompts every tick. |
| Call `granted` through `SettingsModel` | It runs every 2 s and would publish into SwiftUI. Reads go to `HookInstaller`; only the writes go through the model. |
| Put the stepping button in a stack with an invisible spacer | A plain view, the button pinned top, bottom and trailing, and the slack in a view of its own at priority 1. It is unclickable the moment a grant swaps a row's button for a label. |
| Leave it to Auto Layout to decide which view absorbs a page's slack | Decide it. A control handed the slack moves out from under the pointer while still drawing where it was. |
| Retune a spacing, a height or a font size | The owner fitted them in the running window. You cannot see it. |

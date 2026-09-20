import AppKit
import MySidepulseCore

// Before anything is built. The menu, the window and the pushes all read the
// ambient language, and nothing here may show a sentence chosen before it is
// set. Core holds the rule; this is the only place that asks the system.
Loc.language = Language(preferredLanguage: Locale.preferredLanguages.first)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

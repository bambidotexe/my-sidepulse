import AppKit
import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// The app itself: whether it comes back on its own, where it shows, its version, the tip jar,
/// and the way out.
struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(MenuBarController.visiblePrefKey) private var showInMenuBar = true

    var body: some View {
        let t = Loc.settings.general
        SettingsPage {
            SettingsAppIcon()

            SettingsGroup(title: t.startupTitle,
                          hint: t.startupHint,
                          warnings: startupWarnings,
                          notes: [t.startupNote]) {
                ToggleRow(t.openAtLoginToggle,
                          isOn: Binding(get: { model.autoRestartIsOn },
                                        set: { model.setAutoRestart($0) }))
                ToggleRow(t.showInMenuBarToggle, isOn: $showInMenuBar)
            }

            UpdatesGroup()

            // One row, so the hint carries the whole group: the button alone does not say that the
            // app is free, and it opens a web page rather than doing something in the app.
            SettingsGroup(title: t.supportTitle, hint: t.supportHint) {
                ButtonRow {
                    Button(t.supportButton) { NSWorkspace.shared.open(SupportLink.koFi) }
                }
            }

            SettingsGroup(title: t.quitTitle) {
                ButtonRow {
                    Button(t.quitButton, role: .destructive) { model.quit() }
                }
            }

            // The warning is not a state that can be put right: it is the hazard of the other way out,
            // and the button beside it is the way that is not hazardous. It therefore always shows.
            SettingsGroup(title: t.uninstallTitle,
                          hint: t.uninstallHint,
                          warnings: [t.uninstallWarning]) {
                ButtonRow {
                    Button(t.uninstallButton, role: .destructive) { confirmUninstall() }
                }
            }
        }
    }

    /// Asks first, because it takes the app with it, and says afterwards what it could not remove. The
    /// order of the removals, and the two that only a detached helper can do, are `Uninstall`'s.
    private func confirmUninstall() {
        let t = Loc.settings.general
        let alert = NSAlert()
        alert.messageText = t.uninstallConfirmTitle
        alert.informativeText = t.uninstallConfirmBody
        alert.alertStyle = .critical
        alert.addButton(withTitle: t.uninstallConfirmButton)
        alert.addButton(withTitle: t.uninstallCancelButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var failed = Uninstall.removeEverythingOutsideTheBundle().failed
        Uninstall.moveBundleToTrash { trashFailure in
            if let trashFailure { failed.append(trashFailure) }
            if let helperFailure = Uninstall.startHelper() { failed.append(helperFailure) }
            let result = NSAlert()
            result.messageText = failed.isEmpty ? t.uninstallDoneTitle : t.uninstallPartialTitle
            result.informativeText = failed.isEmpty ? t.uninstallDoneBody : failed.joined(separator: "\n\n")
            result.alertStyle = failed.isEmpty ? .informational : .warning
            result.addButton(withTitle: t.uninstallQuitButton)
            result.runModal()
            // Through `NSApp.terminate`, so `applicationShouldTerminate` darkens the strip; the helper
            // is already waiting on this pid.
            model.quit()
        }
    }

    /// Only the mismatch is worth saying: the plist exists but this process is not the one launchd
    /// supervises, so a crash would not be recovered until the next login.
    private var startupWarnings: [String] {
        guard let status = model.status?.loginItem,
              status != "enabled", status != "disabled" else { return [] }
        return [Loc.settings.general.startupWarningOpenedByHand]
    }
}

// MARK: - Updates

/// The version row carries the last answer as its mark, and the one button looks for a release or,
/// once a newer one is known, opens the update window. The app also looks on its own, shortly after
/// launch and then weekly, so the state is the app's (`UpdateController.shared`) and not this view's:
/// what a check found while the window was closed is here when it opens. Which button, and what a
/// press starts, are `UpdatePanel`'s rules.
private struct UpdatesGroup: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        SettingsGroup(title: Loc.settings.general.updatesTitle) {
            StatusRow(updates.appVersion.isEmpty ? "MySidepulse" : "MySidepulse \(updates.appVersion)",
                      mark: mark)
            ButtonRow {
                if updates.panel.offersUpdate {
                    Button(Loc.settings.general.updateButton) { updates.press() }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                } else {
                    Button(Loc.settings.general.checkForUpdatesButton) { updates.press() }
                        .disabled(updates.panel.isBusy)
                }
            }
        }
    }

    private var mark: StatusMark? {
        let t = Loc.settings.general
        switch updates.panel.state {
        case .idle: return nil
        case .checking: return .busy(t.checking)
        case .upToDate: return .good(t.upToDate)
        case .available(let version): return .info(t.versionAvailable(version.displayString))
        case .noRelease: return .warning(t.noReleaseYet)
        case .checkFailed(let reason): return .warning(t.couldNotCheck(reason))
        case .installFailed(let reason): return .warning(t.updateFailed(reason))
        }
    }
}

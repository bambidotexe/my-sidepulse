import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// What MySidepulse needs from outside itself, each beside the button that gives it: Claude Code's
/// hooks, then Codex's, Copilot's and OpenCode's, each in its own group shown only while that agent is on
/// this Mac or its hooks are set up, then the terminal hook in ~/.zshrc, and the notification permission.
/// The hooks are read back from disk and the permission from macOS, so what a row says is what is actually
/// there. Each row's colour is `HealthRules.grant`'s, as on the Health page.
struct SystemPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let t = Loc.settings.system
        SettingsPage {
            SettingsGroup(title: t.claudeCodeTitle,
                          hint: t.claudeCodeHint(events: HookConfig.events.count),
                          warnings: claudeWarnings,
                          notes: [t.claudeCodeNote]) {
                StatusRow(t.claudeCodeHooksLabel, mark: claudeMark)
                ButtonRow {
                    if model.claudeHooksSetUp == true {
                        Button(t.removeHooksButton) { model.removeClaudeHooks() }
                    } else {
                        Button(t.setUpHooksButton) { model.setUpClaudeHooks() }
                    }
                }
            }

            if model.showsCodex {
                SettingsGroup(title: t.codexTitle,
                              hint: t.codexHint(events: HookConfig.codexEvents.count),
                              warnings: codexWarnings,
                              notes: [t.codexNote]) {
                    StatusRow(t.codexHooksLabel, mark: codexMark)
                    ButtonRow {
                        if model.codexHooksSetUp == true {
                            Button(t.removeHooksButton) { model.removeCodexHooks() }
                        } else {
                            Button(t.setUpHooksButton) { model.setUpCodexHooks() }
                        }
                    }
                }
            }

            if model.showsCopilot {
                SettingsGroup(title: t.copilotTitle,
                              hint: t.copilotHint(events: HookConfig.copilotEvents.count),
                              warnings: copilotWarnings,
                              notes: [t.copilotNote]) {
                    StatusRow(t.copilotHooksLabel, mark: copilotMark)
                    ButtonRow {
                        if model.copilotHooksSetUp == true {
                            Button(t.removeHooksButton) { model.removeCopilotHooks() }
                        } else {
                            Button(t.setUpHooksButton) { model.setUpCopilotHooks() }
                        }
                    }
                }
            }

            if model.showsOpenCode {
                SettingsGroup(title: t.opencodeTitle,
                              hint: t.opencodeHint,
                              warnings: opencodeWarnings,
                              notes: [t.opencodeNote]) {
                    StatusRow(t.opencodePluginLabel, mark: opencodeMark)
                    ButtonRow {
                        if model.opencodeHooksSetUp == true {
                            Button(t.removePluginButton) { model.removeOpencodePlugin() }
                        } else {
                            Button(t.setUpPluginButton) { model.setUpOpencodePlugin() }
                        }
                    }
                }
            }

            SettingsGroup(title: t.terminalTitle,
                          hint: t.terminalHint(seconds: Int(K.shellShowAfterDefaultSeconds)),
                          warnings: terminalWarnings,
                          notes: [t.terminalNote]) {
                StatusRow(t.terminalHookLabel,
                          mark: StatusMark(HealthRules.grant(held: model.zshHookSetUp, required: false),
                                           model.zshHookSetUp ? Loc.settings.words.enabled
                                                              : Loc.settings.words.disabled))
                ButtonRow {
                    if model.zshHookSetUp {
                        Button(t.removeTerminalHookButton) { model.removeZshHook() }
                    } else {
                        Button(t.setUpTerminalHookButton) { model.setUpZshHook() }
                    }
                }
            }

            SettingsGroup(title: t.notificationsTitle,
                          hint: Loc.onboarding.notificationsWhy,
                          warnings: model.notificationsGranted == false ? [t.notificationsWarning] : []) {
                StatusRow(t.notificationsPermissionLabel, mark: notificationsMark)
                if model.notificationsGranted == false {
                    ButtonRow {
                        Button(t.allowNotificationsButton) { model.allowNotifications() }
                    }
                }
            }

            SettingsGroup(title: Loc.onboarding.showAgainTitle,
                          hint: Loc.onboarding.showAgainHint) {
                ButtonRow {
                    Button(Loc.onboarding.showAgainButton) { model.showOnboarding?() }
                }
            }
        }
    }

    /// nil is not "off": the file is there and could not be read, which no button can fix. The hooks are
    /// the one thing the strip cannot show Claude without, so missing is red.
    private var claudeMark: StatusMark {
        let words = Loc.settings.words
        switch model.claudeHooksSetUp {
        case true?: return .good(words.enabled)
        case false?: return StatusMark(HealthRules.grant(held: false, required: true), words.disabled)
        case nil: return .failure(words.invalid)
        }
    }

    /// Codex is optional, so missing is orange, and so is a file that cannot be read.
    private var codexMark: StatusMark {
        let words = Loc.settings.words
        switch model.codexHooksSetUp {
        case true?: return .good(words.enabled)
        case false?: return StatusMark(HealthRules.grant(held: false, required: false), words.disabled)
        case nil: return .warning(words.invalid)
        }
    }

    private var codexWarnings: [String] {
        let t = Loc.settings.system
        var warnings: [String] = []
        switch model.codexHooksSetUp {
        case true?:
            break
        case false?:
            warnings.append(t.withoutCodexHooksWarning)
        case nil:
            warnings.append(t.codexHooksUnreadableWarning)
        }
        if let error = model.codexHooksError { warnings.append(error) }
        return warnings
    }

    /// Copilot is optional, so missing is orange, and so is a file belonging to another copy of
    /// MySidepulse (its events do not match this one's) or the hooks turned off by disableAllHooks;
    /// a file that cannot be parsed as JSON reads Invalid instead.
    private var copilotMark: StatusMark {
        let words = Loc.settings.words
        switch model.copilotHooksSetUp {
        case true?:
            return model.copilotHooksDisabled
                ? StatusMark(HealthRules.grant(held: false, required: false), words.disabled)
                : .good(words.enabled)
        case false?: return StatusMark(HealthRules.grant(held: false, required: false), words.disabled)
        case nil: return .warning(words.invalid)
        }
    }

    private var copilotWarnings: [String] {
        let t = Loc.settings.system
        var warnings: [String] = []
        switch model.copilotHooksSetUp {
        case true?:
            if model.copilotHooksDisabled { warnings.append(t.copilotHooksDisabledWarning) }
        case false?:
            warnings.append(t.withoutCopilotHooksWarning)
        case nil:
            warnings.append(t.copilotHooksInvalidWarning)
        }
        if let error = model.copilotHooksError { warnings.append(error) }
        return warnings
    }

    /// OpenCode is optional, so an absent plugin is orange; a plugin that is not this copy's
    /// (`opencodeHooksSetUp == nil`) is Invalid: a stale plugin of another copy of MySidepulse, which
    /// Set Up replaces, or a foreign file, which Set Up refuses and must be removed by hand.
    private var opencodeMark: StatusMark {
        let words = Loc.settings.words
        switch model.opencodeHooksSetUp {
        case true?: return .good(words.enabled)
        case false?: return StatusMark(HealthRules.grant(held: false, required: false), words.disabled)
        case nil: return .warning(words.invalid)
        }
    }

    private var opencodeWarnings: [String] {
        let t = Loc.settings.system
        var warnings: [String] = []
        switch model.opencodeHooksSetUp {
        case true?:
            break
        case false?:
            warnings.append(t.withoutOpencodePluginWarning)
        case nil:
            warnings.append(t.opencodePluginInvalidWarning)
        }
        if let error = model.opencodeHooksError { warnings.append(error) }
        return warnings
    }

    /// Nothing until macOS has answered once: a row that read Denied for the first half second would be
    /// a lie.
    private var notificationsMark: StatusMark? {
        let words = Loc.settings.words
        return model.notificationsGranted.map { granted in
            StatusMark(HealthRules.grant(held: granted, required: false),
                       granted ? words.granted : words.denied)
        }
    }

    /// While the hook is missing, what it costs and the button that sets it up; a set-up or a removal
    /// that failed says why.
    private var terminalWarnings: [String] {
        var warnings: [String] = []
        if !model.zshHookSetUp { warnings.append(Loc.settings.system.withoutTerminalHookWarning) }
        if let error = model.zshHookError { warnings.append(error) }
        return warnings
    }

    private var claudeWarnings: [String] {
        let t = Loc.settings.system
        var warnings: [String] = []
        switch model.claudeHooksSetUp {
        case true?:
            break
        case false?:
            warnings.append(t.withoutHooksWarning)
        case nil:
            warnings.append(t.settingsUnreadableWarning)
        }
        if let error = model.claudeHooksError { warnings.append(error) }
        return warnings
    }
}

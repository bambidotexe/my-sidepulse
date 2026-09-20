import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// What MySidepulse needs from other people's files: Claude Code's settings, and ~/.zshrc.
/// Both are read back from disk, so what a row says is what is actually there.
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

            SettingsGroup(title: t.terminalTitle,
                          hint: t.terminalHint(seconds: Int(K.shellShowAfterDefaultSeconds)),
                          warnings: model.zshHookError.map { [$0] } ?? [],
                          notes: [t.terminalNote]) {
                StatusRow(t.terminalHookLabel,
                          mark: model.zshHookSetUp ? .good(Loc.settings.words.enabled)
                                                   : .info(Loc.settings.words.disabled))
                ButtonRow {
                    if model.zshHookSetUp {
                        Button(t.removeTerminalHookButton) { model.removeZshHook() }
                    } else {
                        Button(t.setUpTerminalHookButton) { model.setUpZshHook() }
                    }
                }
            }
        }
        .onAppear { model.refreshHooks() }
    }

    /// nil is not "off": the file is there and could not be read, which no button can fix.
    private var claudeMark: StatusMark {
        let words = Loc.settings.words
        switch model.claudeHooksSetUp {
        case true?: return .good(words.enabled)
        case false?: return .warning(words.disabled)
        case nil: return .failure(words.invalid)
        }
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

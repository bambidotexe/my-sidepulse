import AppKit
import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// Whether MySidepulse is doing its job, at a glance: one overview row that sums the page up, then every
/// state that bears on it, grouped by subject, each a `StatusRow` in the colour of its level. It reports
/// and changes nothing: a state is put right on the page that owns it, and each orange or red row says
/// where in a warning under its group.
///
/// What goes here, what does not (the version and updates stay on General), and which colour a state
/// takes are the `macos-building-settings-pages` skill's *The Health page*. The rows themselves are built
/// in `HealthReport` (Core), where they are tested; this view only draws them. The window reads the
/// doctor, the hook files and the process when the page is shown (`SettingsModel.readHealth`), never the
/// view.
struct HealthPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let t = Loc.settings.health
        let groups = HealthReport.groups(for: model.healthFacts)
        let summary = HealthSummary(groups: groups)
        SettingsPage {
            SettingsGroup(title: t.overviewTitle) {
                // The doctor has not answered yet the first time the page is shown: its rows are not
                // there, so the overview would sum up half a page.
                StatusRow("MySidepulse",
                          mark: model.isChecking || model.doctor == nil
                            ? .busy(t.checking)
                            : StatusMark(summary.level, HealthReport.summaryWord(summary)))
                ButtonRow {
                    Button(t.checkAgainButton) { model.checkAgain() }
                        .disabled(model.isChecking)
                }
            }

            ForEach(groups) { group in
                SettingsGroup(title: group.title, hint: group.hint, warnings: group.warnings) {
                    ForEach(group.rows) { row in
                        HealthRowView(row: row)
                    }
                }
            }

            SettingsGroup(title: t.reportTitle, hint: t.reportHint) {
                ButtonRow {
                    Button(t.copyReportButton) { copyReport(groups) }
                }
            }
        }
    }

    private func copyReport(_ groups: [HealthGroup]) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = HealthReport.text(appName: "MySidepulse", version: UpdateController.shared.appVersion,
                                     system: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                     groups: groups)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One row of the page: the kit's `StatusRow`, and what only a bug report needs as its tooltip.
private struct HealthRowView: View {
    let row: HealthRow

    var body: some View {
        if let detail = row.detail, !detail.isEmpty {
            StatusRow(row.label, mark: StatusMark(row.level, row.word)).help(detail)
        } else {
            StatusRow(row.label, mark: StatusMark(row.level, row.word))
        }
    }
}

extension StatusMark {
    /// The kit's mark for one of the Health page's four levels: blue, green, orange, red. The System
    /// page's rows take theirs the same way, so a state reads the same on both.
    init(_ level: HealthLevel, _ text: String) {
        switch level {
        case .info: self = .info(text)
        case .good: self = .good(text)
        case .warning: self = .warning(text)
        case .failure: self = .failure(text)
        }
    }
}

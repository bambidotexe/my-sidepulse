import SwiftUI
import MySidepulseCore

/// Whether MySidepulse works, at a glance: two tables and nothing else. **Health** holds the checks, each
/// green, orange or red, with Check Again under them and, while a line is orange or red, the sentence that
/// says where to put it right. **Information** holds a few readings, blue. The page reports and changes
/// nothing: a state is put right on the page that owns it.
///
/// What is a check, what is a reading, what goes on neither (a preference, the version, updates) and how
/// long each table may be are the `macos-building-settings-pages` skill's *The Health page*. The lines are
/// built in `HealthReport` (Core), where they are tested; this view only draws them. The window reads the
/// doctor, the hook files and the crash reports when the page is shown (`SettingsModel.readHealth`), never
/// the view.
struct HealthPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let t = Loc.settings.health
        let facts = model.healthFacts
        let checks = HealthReport.checks(for: facts)
        let readings = HealthReport.readings(for: facts)
        SettingsPage {
            SettingsGroup(title: t.healthTitle, warnings: checks.warnings) {
                ForEach(checks) { row in
                    StatusRow(row.label, mark: StatusMark(row.level, row.word)).help(row.detail ?? "")
                }
                ButtonRow {
                    // The doctor has not answered yet the first time the page is shown: the hooks' line
                    // does not know yet whether they reach a copy of MySidepulse that exists.
                    let busy = model.isChecking || model.doctor == nil
                    if busy { ProgressView().controlSize(.small) }
                    Button(t.checkAgainButton) { model.checkAgain() }
                        .disabled(busy)
                }
            }

            if !readings.isEmpty {
                SettingsGroup(title: t.informationTitle) {
                    ForEach(readings) { row in
                        StatusRow(row.label, mark: .info(row.value)).help(row.detail ?? "")
                    }
                }
            }
        }
    }
}

extension StatusMark {
    /// The kit's mark for one of the Health table's three levels: green, orange, red. The System page's
    /// rows take theirs the same way, so a state reads the same on both.
    init(_ level: HealthLevel, _ text: String) {
        switch level {
        case .good: self = .good(text)
        case .warning: self = .warning(text)
        case .failure: self = .failure(text)
        }
    }
}

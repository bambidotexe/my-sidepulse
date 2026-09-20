import AppKit
import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// The doctor's checks and the live state, in the window instead of a terminal.
struct HealthPage: View {
    @ObservedObject var model: SettingsModel

    /// One doctor check, translated: the name the user knows it by, the mark it earned, and the
    /// raw detail kept for the tooltip.
    private struct Row: Identifiable {
        let id: String
        let label: String
        let mark: StatusMark
        let detail: String
    }

    var body: some View {
        let t = Loc.settings.health
        SettingsPage {
            SettingsGroup(title: t.checksTitle, hint: t.checksHint) {
                ForEach(rows) { row in
                    StatusRow(row.label, mark: row.mark).help(row.detail)
                }
                ButtonRow {
                    Button(t.checkAgainButton) { model.runDoctor() }
                        .disabled(model.doctorRunning)
                }
            }

            SettingsGroup(title: t.rightNowTitle) {
                StatusRow(t.lastHookEventLabel,
                          mark: model.status?.lastEventAgeSeconds
                              .map { .info(t.lastEventAgo(seconds: $0)) } ?? .info(t.noneYet))
                if let battery = model.status?.battery {
                    StatusRow(t.batteryLabel,
                              mark: .info(t.batteryMark(percent: battery.percent,
                                                        plugged: battery.plugged)))
                }
                if sessions.isEmpty {
                    StatusRow(t.claudeSessionsLabel, mark: .info(t.none))
                } else {
                    ForEach(sessions, id: \.id) { session in
                        StatusRow(t.sessionLabel(idPrefix: String(session.id.prefix(8))),
                                  mark: .info(t.sessionMark(state: session.state,
                                                            reason: session.reason,
                                                            ageSeconds: session.ageSeconds)))
                            .help(session.cwd ?? t.unknownDirectory)
                    }
                }
                // A session has no name of its own, so its row says "Session"; a command's
                // row is the command itself.
                ForEach(jobs, id: \.id) { job in
                    StatusRow(job.label ?? job.id,
                              mark: .info(t.jobMark(state: job.state,
                                                    acknowledged: job.acknowledged,
                                                    ageSeconds: job.ageSeconds)))
                }
            }

            SettingsGroup(title: t.reportTitle, hint: t.reportHint) {
                ButtonRow {
                    Button(t.copyReportButton) { copyReport() }
                }
            }
        }
        .onAppear { model.runDoctor() }
    }

    private var sessions: [SessionStatus] { model.status?.sessions ?? [] }

    private var jobs: [JobStatus] { model.status?.jobs ?? [] }

    // MARK: the checks

    /// The doctor's names are its own; these are the user's. A check with no entry here is one the
    /// window reports elsewhere, or a path nobody reads, so it is dropped.
    private var rows: [Row] {
        let t = Loc.settings.health
        let words = Loc.settings.words
        let checks = model.doctor?.checks ?? []
        // The "hook binary" row is about the command "hook command" names, so the tooltip is that
        // check's detail: knowing WHICH path is stale is the whole of the bug report.
        let hookCommandDetail = checks.first(where: { $0.name == "hook command" })?.detail
        return checks.compactMap { check -> Row? in
            switch check.name {
            case "app":
                return Row(id: check.name, label: t.appLabel,
                           mark: check.ok ? .good(words.available) : .failure(words.missing),
                           detail: check.detail)
            case "auto-start & restart":
                return Row(id: check.name, label: t.autoStartLabel,
                           mark: check.ok ? .good(words.enabled) : .warning(words.disabled),
                           detail: check.detail)
            case "hooks installed":
                return Row(id: check.name, label: t.claudeCodeHooksLabel,
                           mark: check.ok ? .good(words.enabled) : .warning(words.disabled),
                           detail: check.detail)
            case "hook binary":
                return Row(id: check.name, label: t.hookCommandLabel,
                           mark: check.ok ? .good(words.valid) : .failure(words.invalid),
                           detail: hookCommandDetail ?? check.detail)
            case "journal":
                return Row(id: check.name, label: t.journalLabel,
                           mark: check.ok ? .good(words.available) : .failure(words.failed),
                           detail: check.detail)
            case "device":
                return Row(id: check.name, label: t.sidePulseStripLabel, mark: deviceMark(check),
                           detail: check.detail)
            case "notifications":
                return Row(id: check.name, label: t.phoneNotificationsLabel,
                           mark: notificationsMark(check), detail: check.detail)
            default:
                return nil
            }
        }
    }

    /// Reads the check's `nuance`, never its sentence: the sentence is prose and
    /// is translated, so matching on it would break in every language but one.
    private func deviceMark(_ check: Doctor.Check) -> StatusMark {
        let words = Loc.settings.words
        guard check.ok else { return .failure(words.failed) }
        switch check.nuance {
        case .stalled: return .warning(words.stalled)
        case .absent: return .warning(words.missing)
        default: return .good(words.available)
        }
    }

    private func notificationsMark(_ check: Doctor.Check) -> StatusMark {
        let words = Loc.settings.words
        guard check.ok else { return .failure(words.invalid) }
        return check.nuance == .disabled ? .good(words.disabled) : .good(words.enabled)
    }

    private func copyReport() {
        var lines = model.doctor.map { run in
            run.checks.map { "\($0.ok ? "[OK]  " : "[FAIL]") \($0.name): \($0.detail)" }
        } ?? []
        if let status = model.status {
            lines.append("")
            lines.append("strip shows: \(status.display ?? "?")   mode: \(status.mode ?? "?")")
            for session in status.sessions ?? [] {
                let reason = session.reason.map { " (\($0))" } ?? ""
                lines.append("session \(session.id.prefix(8)): \(session.state)\(reason), "
                             + "\(session.ageSeconds)s ago")
            }
            for job in status.jobs ?? [] {
                lines.append("job \(job.label ?? job.id): \(job.state), \(job.ageSeconds)s ago")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

import AppKit
import SwiftUI
import MySidepulseCore

/// The phone half of the app: one switch, where it posts, the topic that is effectively a password,
/// and a way to prove it arrives.
struct NotificationsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var server = ""
    @State private var confirmRotate = false

    var body: some View {
        let t = Loc.settings.notifications
        SettingsPage {
            SettingsGroup(title: t.phoneTitle,
                          hint: t.phoneHint,
                          notes: [t.phoneNote]) {
                ToggleRow(t.notifyToggle, isOn: enabledBinding)
            }

            if enabled {
                SettingsGroup(title: t.serverTitle,
                              hint: t.serverHint,
                              warnings: model.notifyStatus?.topicUsable == false
                                  ? [t.serverAddressWarning] : []) {
                    SettingsRow(t.serverLabel) {
                        TextField(t.serverLabel, text: $server, prompt: Text(K.notifyServerDefault))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                            .onSubmit { model.setServer(server) }
                    }
                }

                SettingsGroup(title: t.topicTitle,
                              hint: t.topicHint,
                              warnings: model.newTopicUnsubscribed
                                  ? [t.topicUnsubscribedWarning] : [],
                              notes: model.revealedTopic != nil ? [t.topicScanNote] : []) {
                    if let topic = model.revealedTopic {
                        SettingsRow(t.topicLabel) {
                            Text(topic)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let qr = QRCode.image(for: link(for: topic)) {
                            SettingsRowFrame {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 132, height: 132)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        ButtonRow {
                            Button(t.copyTopicButton) { copy(topic) }
                            Button(t.copyLinkButton) { copy(link(for: topic)) }
                            Button(t.hideButton) { model.hideTopic() }
                        }
                    } else {
                        SettingsRow(t.topicLabel) {
                            Text(model.notifyStatus?.topicMasked ?? "")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ButtonRow {
                            Button(t.revealButton) { model.revealTopic() }
                        }
                    }
                    ButtonRow {
                        Button(t.newTopicButton) { confirmRotate = true }
                    }
                }

                SettingsGroup(title: t.testTitle, hint: t.testHint) {
                    StatusRow(t.testNotificationLabel, mark: testMark)
                    ButtonRow {
                        Button(t.sendTestButton) { model.sendTest() }
                    }
                }
            }
        }
        .onAppear { server = model.notifyStatus?.server ?? "" }
        .onDisappear { model.hideTopic() }
        .confirmationDialog(t.mintDialogTitle, isPresented: $confirmRotate) {
            Button(t.mintDialogButton, role: .destructive) { model.rotateTopic() }
        } message: {
            Text(t.mintDialogMessage)
        }
    }

    private var enabled: Bool { model.notifyStatus?.enabled == true }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.notifyStatus?.enabled ?? false },
                set: { model.setNotifications(enabled: $0) })
    }

    /// What the QR code encodes and Copy Link copies: the subscription URL the ntfy app opens.
    private func link(for topic: String) -> String {
        "\(model.notifyStatus?.server ?? K.notifyServerDefault)/\(topic)"
    }

    private var testMark: StatusMark? {
        switch model.lastTest {
        case .none: return nil
        case .sent?: return .good(Loc.settings.notifications.testSent)
        case .failed(let reason)?:
            return .warning(Loc.settings.notifications.testCouldNotSend(reason))
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

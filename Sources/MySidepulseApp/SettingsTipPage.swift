import AppKit
import MySidepulseCore
import SwiftUI

/// What the app costs, and the one way to say thank you: the app icon beside the sentence that says every
/// feature is free and stays free, then the one offer, which opens the Ko-fi page in the browser.
///
/// The two cards here hold pictures and sentences rather than controls, which no other page does. The owner
/// asked for that look; the rule it departs from is written beside `SettingsGroup`.
struct TipPage: View {
    var body: some View {
        let t = Loc.settings.tip
        SettingsPage {
            // No title: the sentence is the whole of it, and a heading above it would only repeat the
            // page's own.
            SettingsGroup {
                TipIntroRow(text: t.intro)
            }
            SettingsGroup(title: t.offerTitle, hint: t.offerHint(SupportLink.smallestTip)) {
                TipOfferRow(name: t.offerName, description: t.offerDescription,
                            button: t.tipButton(SupportLink.smallestTip))
            }
        }
    }
}

/// The app's own icon, small, and the sentence beside it.
private struct TipIntroRow: View {
    let text: String

    var body: some View {
        SettingsRowFrame {
            HStack(alignment: .center, spacing: SettingsMetrics.tipPictureGap) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: SettingsMetrics.tipAppIconSide, height: SettingsMetrics.tipAppIconSide)
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The one offer: the Ko-fi cup in a tile of its own colour, what the tip is, and the button that opens
/// the page. The button is `.bordered` and not `.borderedProminent`: an update is the window's one
/// prominent action.
private struct TipOfferRow: View {
    let name: String
    let description: String
    let button: String

    var body: some View {
        SettingsRowFrame {
            HStack(alignment: .top, spacing: SettingsMetrics.tipPictureGap) {
                KoFiMark()
                    .fill(KoFiMark.red)
                    .frame(width: SettingsMetrics.tipMarkSide, height: SettingsMetrics.tipMarkSide)
                    .frame(width: SettingsMetrics.tipTileSide, height: SettingsMetrics.tipTileSide)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                            .fill(KoFiMark.red.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                    Text(name)
                        .font(.body)
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(button) { NSWorkspace.shared.open(SupportLink.koFi) }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .padding(.top, SettingsMetrics.rowSpacing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

//
//  GeneralTab.swift
//  ShrikeUI
//
//  General pane — Browser + Navigation rows
//  Only implemented rows are surfaced; planned controls are
//  omitted entirely.
//

import SwiftUI
import ShrikeCore

struct GeneralTab: View {

    /// Spec 27 T1: true for both wheel settings and both fit states.
    static let wheelHelp = "On a trackpad, a short two-finger scroll moves to the next photo when the photo fits the window and the wheel is set to Changes image."


    @EnvironmentObject private var store: PreferencesStore

    // Recent-folders options cross-reference table.
    static let recentOptions: [Int] = [5, 10, 20, 50, 100]

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden files", isOn: store.showHiddenFiles)
                    .accessibilityHint("When on, dotfiles and system folders appear in the browser.")

                // A JPEG+RAW shot is one item by default.
                Picker("RAW+JPEG pairs", selection: store.pairRAW) {
                    Text("Show as one item").tag(true)
                    Text("Show both files").tag(false)
                }
                Text("Press \u{2325}R in the viewer to see the RAW file.")
                    .font(.system(size: ChromeTypography.size(11)))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Store ratings and flags with the file", isOn: store.metadataWriteFileAttributes)
                Text("Keeps them when the file is moved or renamed in Finder.")
                    .font(.system(size: ChromeTypography.size(11)))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Recent folders to remember", selection: store.recentFoldersLimit) {
                    ForEach(SettingsChoices.including(store.recentFoldersLimit.wrappedValue, in: Self.recentOptions),
                            id: \.self) { n in
                        Text(verbatim: "\(n) folders").tag(n)
                    }
                }
            } header: {
                Text("Browsing").font(.headline)
            }

            Section("Viewing") {
                Toggle("Hide the toolbar when the pointer is still", isOn: store.viewerToolbarAutoHide)
                Toggle("Background is always pure black", isOn: store.viewerBackgroundAlwaysBlack)
                Toggle("Position overlay auto-hides after idle", isOn: store.viewerPositionOverlayAutoHides)
                Toggle("Show Review Controls", isOn: store.reviewControlsVisible)
                Toggle("Advance after rating", isOn: store.advanceAfterRating)
                Picker("Text size", selection: store.largerChrome) {
                    Text("Standard").tag(false)
                    Text("Large").tag(true)
                }
            }

            // "Mouse and Trackpad" group.
            Section {
                Picker("Mouse wheel", selection: store.scrollWheelNavigates) {
                    Text("Changes image").tag(true)
                    Text("Zooms").tag(false)
                }
                Text("Hold ⌘ for the other wheel action. Pinch to zoom. Swipe to change photos.")
                DisclosureGroup("More Trackpad Controls") { Text(Self.wheelHelp).fixedSize(horizontal: false, vertical: true) }
            } header: {
                Text("Mouse and Trackpad").font(.headline)
            }
        }
        .formStyle(.grouped)
        .preferencesResetFooter("Reset General to Defaults", tab: .general)
    }
}

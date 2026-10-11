//
//  AdvancedTab.swift
//  ShrikeUI
//
//  Two viewer toggles + destructive "Reset all preferences…" + version footer.
//

import SwiftUI
import ShrikeCore

struct AdvancedTab: View {

    @EnvironmentObject private var store: PreferencesStore

    @State private var showResetAllConfirmation = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Background is always pure black",
                       isOn: store.viewerBackgroundAlwaysBlack)
                    .accessibilityHint(
                        "When off, the viewer background follows the system light/dark theme."
                    )

                Toggle("Position overlay auto-hides after idle",
                       isOn: store.viewerPositionOverlayAutoHides)
                    .accessibilityHint(
                        "On (default): the bottom-left filename pill fades after 2 s. Off keeps it always visible."
                    )
            } header: {
                Text("Viewer").font(.headline)
            }

            Section {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showResetAllConfirmation = true
                    } label: {
                        Label("Reset All Preferences…", systemImage: "xmark.circle.fill")
                    }
                }
            } header: {
                Text("Configuration").font(.headline)
            }

            Section {
                LabeledContent("Version", value: versionString)
            } header: {
                Text("About").font(.headline)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset All Preferences?",
            isPresented: $showResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.notifyAndMutate {
                    Prefs.resetAll()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shrike will return to its default settings. Restart to apply.")
        }
    }
}

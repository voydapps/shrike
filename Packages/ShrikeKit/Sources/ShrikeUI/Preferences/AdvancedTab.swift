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

    /// Spec 27 P3-7: every row is label-left, control-right.
    static let configurationLabel = "Settings"
    static let configurationDetail = "Shrike will return to its default settings. Restart to apply."
    static let versionLabel = "Version"
    /// (leading label, has a trailing control) per row of the last two sections.
    static let rowLabelsForTesting: [(label: String, hasControl: Bool)] = [
        (configurationLabel, true), (versionLabel, false),
    ]

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
                // Spec 27 P3-7: label left, control right; no empty left half.
                LabeledContent {
                    Button(role: .destructive) {
                        showResetAllConfirmation = true
                    } label: {
                        Label("Reset All Preferences…", systemImage: "xmark.circle.fill")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.configurationLabel)
                        Text(Self.configurationDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Configuration").font(.headline)
            }

            Section {
                LabeledContent(Self.versionLabel) {
                    Text(versionString).textSelection(.enabled)
                }
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
            Text(Self.configurationDetail)
        }
    }
}

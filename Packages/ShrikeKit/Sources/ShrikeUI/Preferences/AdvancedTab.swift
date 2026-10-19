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
            Section("Performance") {
                Picker("Browsing Preview Resolution", selection: store.maxDisplayLongEdge) {
                    ForEach(SettingsChoices.including(store.maxDisplayLongEdge.wrappedValue, in: PerformanceTab.longEdgeOptions), id: \.self) { px in
                        Text(verbatim: "\(px) px").tag(px)
                    }
                }
                Text("Limits the preview prepared for browsing. Larger previews use more memory. Shrike loads the original detail when you zoom in.")
                    .font(.system(size: ChromeTypography.size(12))).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                            .font(.system(size: ChromeTypography.size(12)))
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
        .preferencesResetFooter("Reset Advanced to Defaults", tab: .advanced)
        .confirmationDialog(
            "Reset All Preferences?",
            isPresented: $showResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Self.resetAllPreferences(using: store)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Self.configurationDetail)
        }
    }
    /// Apply the confirmed Reset All action through the Settings mutation route.
    @MainActor
    static func resetAllPreferences(using store: PreferencesStore) {
        store.notifyAndMutate {
            PreferencesTab.resetAllToDefaults()
        }
    }

}

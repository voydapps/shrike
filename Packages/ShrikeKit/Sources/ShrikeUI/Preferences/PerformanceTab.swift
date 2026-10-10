//
//  PerformanceTab.swift
//  ShrikeUI
//
//  One row: the viewer decode ceiling. We render just the one active
//  row rather than a wide tab of disabled controls.
//

import SwiftUI
import ShrikeCore

struct PerformanceTab: View {

    @EnvironmentObject private var store: PreferencesStore

    // Cross-reference: 2048 / 3072 / 4096 / 6144 / 8192 px.
    static let longEdgeOptions: [Int] = [2048, 3072, 4096, 6144, 8192]

    var body: some View {
        Form {
            Section {
                Picker("Max decoded long-edge", selection: store.maxDisplayLongEdge) {
                    ForEach(SettingsChoices.including(store.maxDisplayLongEdge.wrappedValue,
                                                      in: Self.longEdgeOptions), id: \.self) { px in
                        Text(verbatim: "\(px) px").tag(px)
                    }
                }

                Text("Larger values use more memory but preserve detail when zooming past 100 %. Default (4096 px) suits most 4K displays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Viewer decode ceiling").font(.headline)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            PreferencesResetFooter(
                label: "Reset Performance to Defaults",
                tab: .performance
            )
            .environmentObject(store)
        }
    }
}

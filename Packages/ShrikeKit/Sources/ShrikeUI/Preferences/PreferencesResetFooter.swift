//
//  PreferencesResetFooter.swift
//  ShrikeUI
//
//  Shared bottom-of-tab reset button. Renders as a subtle secondary link
//  because per-tab resets are low-stakes (only "Reset all preferences" on
//  the Advanced tab is destructive-styled).
//

import SwiftUI
import ShrikeCore

struct PreferencesResetFooter: View {

    let label: String
    let tab: PreferencesTab

    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        HStack {
            Spacer()
            Button(label) {
                store.notifyAndMutate {
                    tab.resetToDefaults()
                }
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}


extension View {
    /// The scroll viewport and reset footer receive separate layout regions.
    /// A safe-area inset on the native grouped Form can let its rows draw and
    /// accept hits beneath the reset link at the viewport edge.
    func preferencesResetFooter(_ label: String, tab: PreferencesTab) -> some View {
        VStack(spacing: 0) {
            self
            PreferencesResetFooter(label: label, tab: tab)
        }
    }
}

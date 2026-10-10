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
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .background(.clear)
    }
}

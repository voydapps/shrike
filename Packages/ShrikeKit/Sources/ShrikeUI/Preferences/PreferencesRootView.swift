//
//  PreferencesRootView.swift
//  ShrikeUI
//
//  SwiftUI root for the Preferences window. Renders just the active tab's
//  body — the toolbar lives on the hosting `NSWindow` (built in
//  `PreferencesWindowController`) because the AppKit-native toolbar is what
//  macOS users expect from a Settings window (uniform height, item-selection
//  state preserved, keyboard focus traversal). A pure-SwiftUI `TabView` would
//  be simpler but wouldn't match the rest of the OS.
//
//  The controller drives tab selection via a binding on this view's
//  `@Published` property on `PreferencesStore`-adjacent state — we expose
//  the property here rather than on `PreferencesStore` to keep the store
//  pure. The window controller owns the selection state source of truth.
//

import SwiftUI
import ShrikeCore
import ShrikeIO

@MainActor
public final class PreferencesSelection: ObservableObject {
    @Published public var tab: PreferencesTab {
        didSet {
            if tab != oldValue {
                PreferencesTab.saveSelected(tab)
            }
        }
    }

    public init(initial: PreferencesTab) {
        self.tab = initial
    }
}

struct PreferencesRootView: View {

    @ObservedObject var selection: PreferencesSelection
    @StateObject private var store = PreferencesStore()

    /// Optional thumbnail cache — passed through to the Thumbnails tab for
    /// disk-usage readout + clear-cache action. nil in test / standalone
    /// previews.
    let thumbnailCache: ThumbnailCache?

    /// Edit backups, for the Editing tab's size line. Nil in tests.
    var backupStore: BackupStore? = nil

    var body: some View {
        Group {
            switch selection.tab {
            case .general:
                GeneralTab()
            case .editing:
                EditingTab(backupStore: backupStore)
            case .shortcuts:
                ShortcutsTab()
            case .thumbnails:
                ThumbnailsTab(thumbnailCache: thumbnailCache)
            case .performance:
                PerformanceTab()
            case .externalEditors:
                ExternalEditorsTab()
            case .advanced:
                AdvancedTab()
            }
        }
        .environmentObject(store)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 460)
    }
}

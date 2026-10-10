//
//  PreferencesTab.swift
//  ShrikeUI
//
//  Typed enum backing the Preferences window's tab selector. Keeps the SwiftUI
//  layer free of magic strings and gives `Prefs.selectedPreferencesTabRaw` a
//  well-known rawValue set.
//
//  Each case owns its identity (stable rawValue), its user-visible label, its
//  SF Symbol, and — important for the "Reset <tab> to defaults" footer — the
//  list of `Prefs` UserDefaults keys that control the tab. Keep the keys in
//  sync with the wiring in the per-tab views below.
//

import Foundation
import ShrikeCore

/// Six Preferences tabs. Order here matches the order they render in the
/// toolbar. `rawValue` is the stable identifier persisted in
/// `Prefs.selectedPreferencesTabRaw`; do not rename without migration.
public enum PreferencesTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case editing
    case shortcuts
    case thumbnails
    case performance
    case externalEditors
    case advanced

    public var id: String { rawValue }

    /// Tab order.
    public static var allCases: [PreferencesTab] {
        [.general, .editing, .shortcuts, .thumbnails, .performance, .externalEditors, .advanced]
    }

    /// Title shown in the toolbar and used as the window title when active.
    public var title: String {
        switch self {
        case .general:         return "General"
        case .editing:         return "Editing"
        case .shortcuts:       return "Shortcuts"
        case .thumbnails:      return "Thumbnails"
        case .performance:     return "Performance"
        case .externalEditors: return "External Editors"
        case .advanced:        return "Advanced"
        }
    }

    /// SF Symbol for the toolbar item, rendered at 24 pt.
    public var symbolName: String {
        switch self {
        case .general:         return "gearshape"
        case .editing:         return "slider.horizontal.3"
        case .shortcuts:       return "keyboard"
        case .thumbnails:      return "square.grid.2x2"
        case .performance:     return "speedometer"
        case .externalEditors: return "square.and.pencil"
        case .advanced:        return "wrench.and.screwdriver"
        }
    }

    /// Every `UserDefaults` key the tab writes to. Used by the per-tab
    /// "Reset <tab> to Defaults" footer: clearing these keys makes every
    /// backing `Prefs.*` accessor fall back to its schema default.
    ///
    /// Shortcuts tab is read-only (no rebind UI), so resetting it is
    /// intentionally narrow: only `shortcutPreset`.
    public var resetKeys: [String] {
        switch self {
        case .general:
            return [
                "shrike.browser.showHiddenFiles",
                "shrike.recent.foldersLimit",
                "shrike.input.scrollWheelNavigates",
                "shrike.grouping.pairRAW",
                "shrike.metadata.writeFileAttributes",
            ]
        case .editing:
            return [
                "shrike.edit.jpegQualityDefault",
                "shrike.edit.heicQualityDefault",
                "shrike.edit.preserveEXIFOnSave",
                "shrike.edit.stripGPSOnSave",
                "shrike.backups.retentionDays",
            ]
        case .shortcuts:
            return ["shrike.shortcuts.preset"]
        case .thumbnails:
            return [
                "shrike.thumbnails.sizePt",
                "shrike.cache.diskCeilingBytes",
            ]
        case .performance:
            return ["shrike.viewer.maxDisplayLongEdge"]
        case .externalEditors:
            // The registry, and the old list it imports once (else a reset
            // would bring the old editors back on the next launch).
            return ["shrike.editors.registry", "shrike.editors.slots"]
        case .advanced:
            return [
                "shrike.viewer.backgroundAlwaysBlack",
                "shrike.viewer.positionOverlayAutoHides",
            ]
        }
    }

    /// Clear the tab's backing keys. The Prefs getters fall back to their
    /// literal defaults once the underlying key is absent, so no second pass
    /// is needed.
    @MainActor
    public func resetToDefaults() {
        if self == .externalEditors { ExternalEditors.registry.removeAll() }
        let defaults = ShrikeDefaults.store
        for key in resetKeys {
            defaults.removeObject(forKey: key)
        }
        if resetKeys.contains("shrike.grouping.pairRAW") {
            NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
        }
    }

    // MARK: - Persistence helpers

    /// Read the last-used tab from `Prefs`, falling back to `.general`.
    public static func loadSelected() -> PreferencesTab {
        guard let raw = Prefs.selectedPreferencesTabRaw,
              let tab = PreferencesTab(rawValue: raw)
        else { return .general }
        return tab
    }

    /// Persist the current selection so the window opens on the same tab
    /// next time.
    public static func saveSelected(_ tab: PreferencesTab) {
        Prefs.selectedPreferencesTabRaw = tab.rawValue
    }
}

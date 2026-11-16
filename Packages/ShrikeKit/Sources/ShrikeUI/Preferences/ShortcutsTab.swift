//
//  ShortcutsTab.swift
//  ShrikeUI
//
//  Settings ▸ Shortcuts. The preset popup, one line of help and a button that
//  opens the Keyboard Shortcuts window. The long list lives only
//  there; its rows come from `ShortcutsTab.sections(for:)`, which reads
//  `ShortcutTable` — the same rows the keymaps and the menu bar use.
//

import SwiftUI
import ShrikeCore

struct ShortcutsTab: View {

    @State private var selectedPreset: ShortcutPreset = Prefs.shortcutPreset

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $selectedPreset) {
                    Text("Mac").tag(ShortcutPreset.macNative)
                    Text("FastStone").tag(ShortcutPreset.fastStoneCompat)
                }
                .onChange(of: selectedPreset) { _, newValue in
                    Prefs.shortcutPreset = newValue
                }
                Text(Self.presetHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // An AppKit button that names itself (SwiftUI's left it unnamed).
                BatchTextButton(Self.showAllTitle) { ShortcutsWindowController.shared.show() }
                    .fixedSize()
            }
        }
        .formStyle(.grouped)
    }

    static let presetHelp = "Choose a preset. Use Show All Shortcuts… to see every key."
    static let showAllTitle = "Show All Shortcuts…"

    struct Row: Equatable { let action: String; let keys: String }

    /// The key column's font: the system font, as the menus use. SF Mono
    /// has no ⇞ ⇟ ↩ ⇥ glyphs and its fallback drew Page Up / Page Down
    /// as "•"; the system font falls back to Lucida
    /// Grande, which has every Mac key symbol.
    static let keysFontSize: CGFloat = 12
    struct SectionModel: Equatable { let title: String; let rows: [Row] }

    /// The rows the tab shows, grouped by context, one row per command in
    /// table order.
    static func sections(for preset: ShortcutPreset) -> [SectionModel] {
        let contexts: [(ShortcutContext, String)] = [
            (.viewer, "Viewer"), (.browser, "Browser"), (.editMode, "Edit Mode"), (.compare, "Compare"),
        ]
        return contexts.map { context, title in
            var seen = Set<ShrikeCommand>()
            var rows: [Row] = []
            for row in ShortcutTable.rows(for: preset)
            where row.context == context && seen.insert(row.command).inserted {
                // Best Fit runs the same code as Zoom to Fit: one row, all its keys.
                if row.command == .zoomBestFit { continue }
                var keys = ShortcutTable.displayString(for: row.command, context: context, preset: preset)
                if row.command == .zoomToFit {
                    let twin = ShortcutTable.displayString(for: .zoomBestFit, context: context, preset: preset)
                    if !twin.isEmpty { keys += ", " + twin }
                }
                rows.append(Row(action: row.command.shortcutsTabTitle, keys: keys))
            }
            return SectionModel(title: title, rows: rows)
        }
    }
}

extension ShrikeCommand {
    /// The words for the star glyph titles ("★★★" is read as "black star" three times).
    var accessibleRatingTitle: String? {
        switch self {
        case .rate1: return "Rate 1 Star"
        case .rate2: return "Rate 2 Stars"
        case .rate3: return "Rate 3 Stars"
        case .rate4: return "Rate 4 Stars"
        case .rate5: return "Rate 5 Stars"
        default: return nil
        }
    }

    /// Menu titles that only make sense inside their submenu get context.
    var shortcutsTabTitle: String {
        switch self {
        case .rate0: return "Rating: None"
        case .rate1, .rate2, .rate3, .rate4, .rate5: return accessibleRatingTitle ?? "Rating: \(title)"
        case .viewAsGrid, .viewAsFilmstrip, .viewAsList: return "View \(title)"
        case .sortByName, .sortByDateCaptured, .sortByDateModified, .sortBySize,
             .sortByRating, .sortByKind, .sortByDimensions: return "Sort by \(title)"
        case .toggleSidebar, .toggleToolbar, .toggleInspector, .toggleFilmstrip,
             .toggleHistogram:
            return title.replacingOccurrences(of: "Show ", with: "Show/Hide ")
        case .toggleFullScreen: return "Full Screen"
        default: return title.replacingOccurrences(of: "…", with: "")
        }
    }
}

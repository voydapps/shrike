//
//  ShortcutsTab.swift
//  ShrikeUI
//
//  Settings ▸ Shortcuts. A preset popup and a
//  read-only list of every key the preset uses, read from `ShortcutTable`
//  — the same rows the keymaps and the menu bar use, so the list can
//  never drift from what the keys do.
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
                Text("Choose a preset. The list shows every key it uses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Search all keys with Help ▸ Keyboard Shortcuts (⌘/).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(ShortcutsTab.sections(for: selectedPreset), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.action) { row in
                        LabeledContent(row.action) {
                            Text(row.keys)
                                .font(.system(size: ShortcutsTab.keysFontSize))
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

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
                rows.append(Row(
                    action: row.command.shortcutsTabTitle,
                    keys: ShortcutTable.displayString(for: row.command, context: context, preset: preset)
                ))
            }
            return SectionModel(title: title, rows: rows)
        }
    }
}

extension ShrikeCommand {
    /// Menu titles that only make sense inside their submenu get context.
    var shortcutsTabTitle: String {
        switch self {
        case .rate0: return "Rating: None"
        case .rate1, .rate2, .rate3, .rate4, .rate5: return "Rating: \(title)"
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

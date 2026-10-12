//
//  MenuKeyHints.swift
//  ShrikeUI
//
//  Bare keys shown in menus (spec 25 §13.1). A bare key must never be a
//  menu `keyEquivalent` (the menu would take "q" before a search field
//  sees it), so the hint is drawn inside the title, right-aligned with a
//  tab stop. Display only: the key keeps working through the window keymaps.
//

import AppKit
import ShrikeCore

@MainActor
enum MenuKeyHints {

    /// Separates the title from the hint in an attributed title.
    private static let tab = "\t"

    /// The bare key for `command` in the live preset: the first binding
    /// with no modifier at all, from `context` (then the other window context).
    static func hint(for command: ShrikeCommand, context: ShortcutContext,
                     preset: ShortcutPreset = ShortcutTable.livePreset) -> String? {
        for ctx in [context, context == .viewer ? ShortcutContext.browser : .viewer] {
            let binding = ShortcutTable.bindings(for: command, context: ctx, preset: preset)
                .first { $0.modifiers.intersection([.command, .option, .control, .shift]).isEmpty && !$0.isFunctionKey }
            if let binding { return binding.displayString }
        }
        return nil
    }

    /// A function-key binding (F2, F5) shown as a real key on a context-menu
    /// row, with the binding's own modifiers (none), never the default ⌘.
    static func applyFunctionKey(to item: NSMenuItem, command: ShrikeCommand) {
        guard let binding = ShortcutTable.menuBinding(for: command), let key = binding.menuKeyEquivalent else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = binding.modifiers
    }

    /// The title without its hint.
    static func baseTitle(of item: NSMenuItem) -> String {
        let title = item.attributedTitle?.string ?? item.title
        return title.components(separatedBy: tab).first ?? title
    }

    /// Draws the hints of `menu` and its submenus. Items with a real
    /// `keyEquivalent` keep it and get no hint; a stale hint is removed.
    static func apply(to menu: NSMenu, context: ShortcutContext,
                      preset: ShortcutPreset = ShortcutTable.livePreset,
                      hasOwnKey: (NSMenuItem) -> Bool = { !$0.keyEquivalent.isEmpty }) {
        let font = NSFont.menuFont(ofSize: 0)
        var hinted: [(NSMenuItem, String, String)] = []
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu, context: context, preset: preset, hasOwnKey: hasOwnKey) }
            let base = baseTitle(of: item)
            // The rows of Copy / Move to Folder ▸ are not the command's key (C / M start the chord).
            let isDestinationRow = item.submenu == nil
                && [ShrikeCommand.copyToFolder.title, ShrikeCommand.moveToFolder.title].contains(menu.title)
            if let command = item.shrikeCommand, !hasOwnKey(item), !item.isSeparatorItem, !isDestinationRow,
               let text = hint(for: command, context: context, preset: preset) {
                hinted.append((item, base, text))
            } else if item.attributedTitle != nil, item.attributedTitle?.string.contains(tab) == true {
                item.attributedTitle = nil
                item.title = base
            }
        }
        guard !hinted.isEmpty else { return }
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let titleWidth = menu.items.map { width(baseTitle(of: $0)) }.max() ?? 0
        let stop = ceil(titleWidth) + 24 + ceil(hinted.map { width($0.2) }.max() ?? 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: stop)]
        for (item, base, text) in hinted {
            let out = NSMutableAttributedString(
                string: base + tab, attributes: [.font: font, .paragraphStyle: style])
            out.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            item.attributedTitle = out
        }
    }
}

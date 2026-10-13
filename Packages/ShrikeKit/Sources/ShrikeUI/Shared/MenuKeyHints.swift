//
//  MenuKeyHints.swift
//  ShrikeUI
//
//  Bare keys shown in menus (spec 25 §13.1). A bare key must never be a
//  menu `keyEquivalent` (the menu would take "q" before a search field
//  sees it), so the hint is an `NSMenuItemBadge` in the key column (the user
//  chose badges over a tab-stop column, 2026-10-13). Display only: the key
//  keeps working through the window keymaps.
//

import AppKit
import ShrikeCore

@MainActor
enum MenuKeyHints {

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

    /// The title of the item (nothing is drawn into it any more).
    static func baseTitle(of item: NSMenuItem) -> String { item.title }

    /// The hint badge text of an item, if it has one.
    static func badgeText(of item: NSMenuItem) -> String? { item.badge?.stringValue }

    /// Gives the items of `menu` and its submenus their hint badge. Items with a
    /// real `keyEquivalent` keep it and get no badge; a stale badge is removed.
    static func apply(to menu: NSMenu, context: ShortcutContext,
                      preset: ShortcutPreset = ShortcutTable.livePreset,
                      hasOwnKey: (NSMenuItem) -> Bool = { !$0.keyEquivalent.isEmpty }) {
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu, context: context, preset: preset, hasOwnKey: hasOwnKey) }
            // The rows of Copy / Move to Folder ▸ are not the command's key (C / M start the chord).
            let isDestinationRow = item.submenu == nil
                && [ShrikeCommand.copyToFolder.title, ShrikeCommand.moveToFolder.title].contains(menu.title)
            if let command = item.shrikeCommand, !hasOwnKey(item), !item.isSeparatorItem, !isDestinationRow,
               let text = hint(for: command, context: context, preset: preset) {
                if item.badge?.stringValue != text { item.badge = NSMenuItemBadge(string: text) }
            } else if item.badge != nil {
                item.badge = nil
            }
        }
    }
}

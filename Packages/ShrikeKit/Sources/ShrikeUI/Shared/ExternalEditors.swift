//
//  ExternalEditors.swift
//  ShrikeUI
//
//  External editors in the UI:
//
//    * File ▸ Open in External Editor ▸ and the same submenu in the
//      viewer's and the Browser's right-click menus: one row per
//      `ExternalEditorRegistry` entry with its key (⌥⌘1 … ⌥⌘9 from the
//      shortcut table), then "Edit External Editors…". An empty list
//      shows only "Set Up External Editors…".
//    * The launch: the viewer's displayed item or the Browser selection,
//      one file per item (Send RAW picks the RAW of a pair). A missing or
//      moved app gives a toast with a Settings button; the slot stays.
//    * An empty slot's key opens Settings ▸ External Editors (the key is
//      never dead).
//
//  The registry is the only store (`shrike.editors.registry`); the old
//  3-slot `Prefs.externalEditors` list is imported once by the registry
//  and never read here.
//

import AppKit
import ShrikeCore
import ShrikeIO

@MainActor
public enum ExternalEditors {

    // MARK: Seams

    /// The registry the menus, keys and Settings read. Tests set a
    /// registry with a fake workspace, so no app is ever launched.
    public static var registry: ExternalEditorRegistry {
        get { registryOverride ?? ExternalEditorRegistry.shared }
        set { registryOverride = newValue }
    }
    private static var registryOverride: ExternalEditorRegistry?

    /// Test seam: back to the shared registry.
    static func resetRegistryForTesting() { registryOverride = nil }

    /// Opens Settings ▸ External Editors. `AppCommands` sets it.
    public static var openSettingsTab: () -> Void = {}

    // MARK: Copy

    static let editTitle = "Edit External Editors…"
    static let setUpTitle = "Set Up External Editors…"

    /// Toast for a missing or moved app.
    static func missingApp(_ name: String) -> String {
        "Couldn't open “\(name)”. It may have been moved or deleted."
    }

    static func launchFailed(_ name: String) -> String {
        "Couldn't open the file in “\(name)”."
    }

    // MARK: Submenu

    /// Fills an Open in External Editor ▸ submenu. Editor rows send
    /// `performShrikeCommand:` to `target` (nil = responder chain).
    /// Nothing here touches the disk: no app icons, no path checks.
    static func fill(_ menu: NSMenu, target: AnyObject?) {
        menu.removeAllItems()
        let editors = registry.editors.prefix(ExternalEditorRegistry.maxEditors)
        for (slot, editor) in editors.enumerated() {
            let command = ShrikeCommand.externalEditorCommands[slot]
            let item = NSMenuItem(title: editor.displayName, action: ShrikeMainMenu.commandAction,
                                  keyEquivalent: "")
            item.representedObject = command.rawValue
            item.target = target
            item.tag = slot + 1
            if let binding = ShortcutTable.menuBinding(for: command), let key = binding.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = binding.modifiers
            }
            menu.addItem(item)
        }
        if !editors.isEmpty { menu.addItem(.separator()) }
        let settings = NSMenuItem(title: editors.isEmpty ? setUpTitle : editTitle,
                                  action: #selector(ExternalEditorSettingsOpener.openSettings(_:)),
                                  keyEquivalent: "")
        settings.target = ExternalEditorSettingsOpener.shared
        menu.addItem(settings)
    }

    // MARK: Launch

    /// A toast request: the content and its button's action.
    typealias ToastSink = @MainActor (ToastContent, (@MainActor () -> Void)?) -> Void

    /// Opens `groups` with the editor in `slot`. An empty slot opens
    /// Settings instead. Errors end in a toast; nothing fails silently.
    @discardableResult
    static func open(groups: [ImageGroup], slot: Int, toast: @escaping ToastSink) -> Task<Void, Never>? {
        guard !groups.isEmpty else { return nil }
        let registry = self.registry
        guard let editor = registry.editor(inSlot: slot) else {
            openSettingsTab()
            return nil
        }
        return Task { @MainActor in
            do {
                try await registry.open(groups: groups, with: editor)
            } catch ExternalEditorError.applicationNotFound(let name) {
                toast(ToastContent(missingApp(name), kind: .error, actionTitle: "Settings")) {
                    ExternalEditors.openSettingsTab()
                }
            } catch ExternalEditorError.fileNotFound(let url) {
                toast(ToastContent("Couldn't open “\(url.lastPathComponent)”. It no longer exists.",
                                   kind: .error), nil)
            } catch {
                toast(ToastContent(launchFailed(editor.displayName), kind: .error), nil)
            }
        }
    }
}

/// The Open in External Editor ▸ submenu of a right-click menu. It is
/// filled when it opens, like the menu bar's; rows go to `target`.
@MainActor
final class ExternalEditorsSubmenu: NSObject, NSMenuDelegate {
    static let title = "Open in External Editor"

    let menu = NSMenu(title: ExternalEditorsSubmenu.title)
    private weak var target: AnyObject?

    init(target: AnyObject?) {
        self.target = target
        super.init()
        menu.delegate = self
    }

    /// The parent row to add to the right-click menu.
    func makeParentItem() -> NSMenuItem {
        let parent = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) { ExternalEditors.fill(menu, target: target) }
}

/// Target of the "Edit / Set Up External Editors…" rows.
@MainActor
final class ExternalEditorSettingsOpener: NSObject {
    static let shared = ExternalEditorSettingsOpener()
    @objc func openSettings(_ sender: Any?) { ExternalEditors.openSettingsTab() }
}

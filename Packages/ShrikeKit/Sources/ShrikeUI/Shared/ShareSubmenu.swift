//
//  ShareSubmenu.swift
//  ShrikeUI
//
//  Share ▸: the system share services
//  (AirDrop, Mail, Messages, Notes…) for the photo on screen, with its
//  RAW sibling, or for the Browser selection. One helper for the File
//  menu and the viewer's and Browser's right-click menus.
//
//  Before this, the menus held `NSSharingServicePicker.standardShareMenuItem`
//  from a picker nobody kept; the item's (weak) target went away and the
//  row stayed disabled.
//
//  Lazy: the services are looked up only when the submenu opens; the
//  parent row only checks whether there is anything to share.
//

import AppKit
import ShrikeCore

@MainActor
final class ShareSubmenu: NSObject, NSMenuDelegate {

    /// "Share" (a submenu, so no ellipsis).
    static var title: String { ShrikeCommand.share.title }

    let menu = NSMenu(title: ShareSubmenu.title)
    /// The row that opens `menu` (see `makeParentItem()`).
    private(set) weak var parentItem: NSMenuItem?
    /// The files to share, read when a menu opens.
    private let files: () -> [URL]

    /// Services for the files. Tests swap it for a fixed list.
    static var servicesProvider: ([URL]) -> [NSSharingService] = { urls in
        (LegacyServiceLookup() as any ShareServiceLookup).services(for: urls)
    }

    init(files: @escaping () -> [URL]) {
        self.files = files
        super.init()
        menu.delegate = self
    }

    /// The parent row. Call `refreshParent()` when its menu opens (or
    /// make this object that menu's delegate with `ownsParentMenu`).
    func makeParentItem() -> NSMenuItem {
        let parent = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        parent.representedObject = ShrikeCommand.share.rawValue
        parentItem = parent
        refreshParent()
        return parent
    }

    /// Enables the row when there is something to share; with nothing,
    /// a disabled "Share" row with no submenu.
    func refreshParent() {
        guard let parent = parentItem else { return }
        let hasFiles = !files().isEmpty
        parent.submenu = hasFiles ? menu : nil
        parent.isEnabled = hasFiles
    }

    /// Parent menus without a delegate of their own (the Browser's
    /// right-click menu) let this object refresh the row.
    func ownParentMenu(_ parentMenu: NSMenu) {
        parentMenu.delegate = self
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            Self.fill(menu, urls: files(), target: self)
        } else {
            refreshParent()
        }
    }

    /// One row per service, with its system icon and title.
    static func fill(_ menu: NSMenu, urls: [URL], target: ShareSubmenu) {
        menu.removeAllItems()
        let services = urls.isEmpty ? [] : servicesProvider(urls)
        guard !services.isEmpty else {
            let none = NSMenuItem(title: "No Sharing Services", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for service in services {
            let item = NSMenuItem(title: service.menuItemTitle,
                                  action: #selector(ShareSubmenu.share(_:)), keyEquivalent: "")
            item.target = target
            let icon = service.image.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = ShareRequest(service: service, urls: urls)
            menu.addItem(item)
        }
    }

    @objc func share(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ShareRequest else { return }
        request.service.perform(withItems: request.urls)
    }

    /// The files Share ▸ sends for one photo: the display file and its
    /// RAW sibling (a RAW+JPEG pair), not sidecars or Live Photo movies.
    nonisolated static func files(of group: ImageGroup) -> [URL] {
        [group.primary] + group.companions.filter { $0.kind == .raw }.map(\.url)
    }
}

/// What a service row shares.
final class ShareRequest: NSObject {
    let service: NSSharingService
    let urls: [URL]
    init(service: NSSharingService, urls: [URL]) {
        self.service = service
        self.urls = urls
    }
}

/// `sharingServices(forItems:)` is the only API that lists the services
/// for a submenu; macOS 13 deprecated it in favour of the picker's
/// "Share…" row, which is not a submenu. Calling it through this protocol
/// keeps the deprecation note out of Release builds (warnings are errors).
private protocol ShareServiceLookup {
    func services(for items: [Any]) -> [NSSharingService]
}

private struct LegacyServiceLookup: ShareServiceLookup {
    @available(macOS, deprecated: 13.0)
    func services(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}

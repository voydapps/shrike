//
//  ViewerContextMenu.swift
//  ShrikeUI
//
//  The viewer's right-click menu:
//
//    Open With ▸ · Open in External Editor ▸ · Reveal in Finder · Show in Browser · Share ▸ · —
//    Rotate Left · Rotate Right · Edit Image · — · Rating ▸ · Flag · Tags… · —
//    Copy to Folder ▸ · Move to Folder ▸ · Rename… · Revert to Original…
//    (when edited) · — · Copy · Copy Path · — · Move to Trash
//
//  Command rows send `performShrikeCommand:` to the viewer, so they share
//  the menu bar's `canPerform` / `perform` and its check marks. The
//  Copy / Move to Folder ▸ rows are the destination slots. The
//  menu is built on first open and refreshed on every open; nothing is
//  built at window launch.
//

import AppKit
import ShrikeCore

@MainActor
final class ViewerContextMenu: NSObject, NSMenuDelegate {

    let menu = NSMenu(title: "Viewer")
    private weak var window: ViewerWindow?
    private let openWithMenu = NSMenu(title: "Open With")
    private let copyToMenu = NSMenu(title: ShrikeCommand.copyToFolder.title)
    private let moveToMenu = NSMenu(title: ShrikeCommand.moveToFolder.title)
    private var built = false
    private var revertItem: NSMenuItem?
    /// Share ▸.
    private lazy var share = ShareSubmenu(files: { [weak self] in self?.window?.shareFileURLs ?? [] })
    private var editors: ExternalEditorsSubmenu?

    init(window: ViewerWindow) {
        self.window = window
        super.init()
        menu.delegate = self
        openWithMenu.delegate = self
        copyToMenu.delegate = self
        moveToMenu.delegate = self
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let window else { return }
        switch menu {
        case self.menu:
            if !built { build() }
            revertItem?.isHidden = !window.isDisplayedEdited
            share.refreshParent()
            ShrikeMainMenu.tidySeparators(in: menu)
            MenuKeyHints.apply(to: menu, context: .viewer)
        case copyToMenu:
            ShrikeMainMenu.fillDestinations(copyToMenu, command: .copyToFolder,
                                           slots: window.transfers.slots, target: window)
        case moveToMenu:
            ShrikeMainMenu.fillDestinations(moveToMenu, command: .moveToFolder,
                                           slots: window.transfers.slots, target: window)
        case openWithMenu:
            fillOpenWith()
        default:
            break
        }
    }

    /// Builds and refreshes the menu as if it were about to open (tests).
    func prepareForTesting() {
        menuNeedsUpdate(menu)
        menuNeedsUpdate(copyToMenu)
        menuNeedsUpdate(moveToMenu)
        if let editors { editors.menuNeedsUpdate(editors.menu) }
    }

    // MARK: Build

    private func build() {
        built = true
        guard let window else { return }
        addSubmenu(openWithMenu, title: "Open With")
        let editors = ExternalEditorsSubmenu(target: window)
        self.editors = editors
        menu.addItem(editors.makeParentItem())
        add(.toggleRAWFile, target: window)
        add(.revealInFinder, target: window)
        add(.showInBrowser, target: window)
        menu.addItem(share.makeParentItem())
        // Same three, same order as the Browser's menu.
        add(.slideshow, target: window)
        add(.batch, target: window)
        add(.compare, target: window)
        menu.addItem(.separator())
        add(.rotateLeft, target: window)
        add(.rotateRight, target: window)
        add(.editImage, target: window)
        menu.addItem(.separator())
        let rating = NSMenu(title: "Rating")
        for command in [ShrikeCommand.rate0, .rate1, .rate2, .rate3, .rate4, .rate5] {
            rating.addItem(item(command, target: window))
        }
        addSubmenu(rating, title: "Rating")
        add(.toggleFlag, target: window)
        add(.tags, target: window)
        menu.addItem(.separator())
        addSubmenu(copyToMenu, title: copyToMenu.title, command: .copyToFolder)
        addSubmenu(moveToMenu, title: moveToMenu.title, command: .moveToFolder)
        MenuKeyHints.applyFunctionKey(to: add(.rename, target: window), command: .rename)
        revertItem = add(.revertToOriginal, target: window)
        menu.addItem(.separator())
        // "Copy" is the ⌘C action, file + image.
        add(.copy, target: window, title: "Copy")
        add(.copyPath, target: window)
        menu.addItem(.separator())
        add(.moveToTrash, target: window)
    }

    private func item(_ command: ShrikeCommand, target: AnyObject, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? command.title, action: ShrikeMainMenu.commandAction,
                              keyEquivalent: "")
        item.representedObject = command.rawValue
        item.target = target
        return item
    }

    @discardableResult
    private func add(_ command: ShrikeCommand, target: AnyObject, title: String? = nil) -> NSMenuItem {
        let made = item(command, target: target, title: title)
        menu.addItem(made)
        return made
    }

    private func addSubmenu(_ submenu: NSMenu, title: String, command: ShrikeCommand? = nil) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        if let command { parent.representedObject = command.rawValue }
        menu.addItem(parent)
    }

    // MARK: Open With ▸ (system apps)

    private func fillOpenWith() {
        OpenWithMenu.fill(openWithMenu, url: window?.commandFileURLs.first, target: self,
                          action: #selector(openWith(_:)))
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let url = window?.commandFileURLs.first else { return }
        OpenWithMenu.open([url], with: sender)
    }

    // MARK: Test seams

    var copyToMenuForTesting: NSMenu { copyToMenu }
    var moveToMenuForTesting: NSMenu { moveToMenu }
}

extension ViewerWindow {
    /// The displayed file has a Shrike edit that Revert can undo.
    var isDisplayedEdited: Bool {
        guard let primary = displayedItem?.group.primary else { return false }
        return fileBadges[primary]?.edited ?? false
    }
}

/// Open With ▸ (system apps), shared by the viewer's and the grid's right-click menus.
@MainActor
enum OpenWithMenu {
    /// Fills `menu` with the apps that can open `url` (the default one marked).
    static func fill(_ menu: NSMenu, url: URL?, target: AnyObject, action: Selector) {
        menu.removeAllItems()
        func none() {
            let row = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        guard let url else { return none() }
        let workspace = NSWorkspace.shared
        let apps = workspace.urlsForApplications(toOpen: url)
            .filter { $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
        let fallback = workspace.urlForApplication(toOpen: url)
        for app in apps.prefix(20) {
            let title = FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            let row = NSMenuItem(title: app == fallback ? "\(title) (default)" : title,
                                 action: action, keyEquivalent: "")
            row.target = target
            row.representedObject = app
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            row.image = icon
            menu.addItem(row)
        }
        if menu.items.isEmpty { none() }
    }

    /// Opens `urls` with the app a row of `fill` carries.
    static func open(_ urls: [URL], with row: NSMenuItem) {
        guard let app = row.representedObject as? URL, !urls.isEmpty else { return }
        // No completion handler. NSWorkspace calls it on a background
        // queue, and a closure written here would be main-actor isolated,
        // so Swift 6 would trap when it runs.
        NSWorkspace.shared.open(urls, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }
}

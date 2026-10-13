//
//  ShrikeMainMenu.swift
//  ShrikeUI
//
//  The menu bar (the single final table).
//
//  * Every key equivalent comes from `ShortcutTable.menuBinding(for:)`.
// No key is written here.
//  * Window commands send `performShrikeCommand:` (or a standard AppKit
//    selector) to the responder chain; `ViewerWindow` and
//    `BrowserWindowController` validate them (`NSMenuItemValidation`).
//    With no Browser or Viewer key, nothing answers and AppKit greys them.
//  * The main window decides which surface's items show.
//    Items of the other surface are hidden AND lose their key, because
//    AppKit still fires the keys of hidden items (⌘1–3, ⌘+/−, ⌘↑, …).
//  * Launch cost: no symbol images, no file or pref reads while building.
//    Open Recent, Copy/Move to Folder, External Editors, Sort By and
//    Share fill in `menuNeedsUpdate(_:)`.
//

import AppKit
import ShrikeCore

// MARK: - Surface

/// Which kind of window is main.
public enum MenuSurface: Sendable, Equatable, CaseIterable {
    case browser, viewer, viewerEditMode, other

    @MainActor
    public static func of(_ window: NSWindow?) -> MenuSurface {
        if let viewer = window as? ViewerWindow {
            return viewer.contentRoot.isEditModeActive ? .viewerEditMode : .viewer
        }
        if window?.windowController is BrowserWindowController { return .browser }
        if window?.delegate is BrowserWindowController { return .browser }
        return .other
    }
}

/// Where an item shows.
public enum MenuPlacement: Sendable, Equatable {
    case both, browser, viewer

    func isVisible(on surface: MenuSurface) -> Bool {
        switch (self, surface) {
        case (.both, _): return true
        case (.browser, .browser): return true
        case (.viewer, .viewer), (.viewer, .viewerEditMode): return true
        default: return false
        }
    }
}

// MARK: - Responder-chain protocol

/// The selector every window command item sends (target nil).
@MainActor
@objc public protocol ShrikeMenuActions {
    func performShrikeCommand(_ sender: Any?)
}

/// A window that runs menu commands: `ViewerWindow`,
/// `BrowserWindowController`.
@MainActor
public protocol ShrikeCommandTarget: AnyObject {
    /// False greys the item (the "Disabled when" column).
    func canPerform(_ command: ShrikeCommand) -> Bool
    func perform(_ command: ShrikeCommand)
    /// Checkmark for view-state items.
    func menuState(for command: ShrikeCommand) -> NSControl.StateValue
    /// Files that Open… starts next to.
    var commandFileURLs: [URL] { get }
    /// Files that Share ▸ shares (a photo with its RAW sibling).
    var shareFileURLs: [URL] { get }
}

public extension ShrikeCommandTarget {
    var shareFileURLs: [URL] { commandFileURLs }
}

public extension NSMenuItem {
    /// The command this item runs, if it is a command item.
    var shrikeCommand: ShrikeCommand? {
        (representedObject as? String).flatMap(ShrikeCommand.init(rawValue:))
    }
}

// MARK: - Menu

@MainActor
public final class ShrikeMainMenu: NSObject, NSMenuDelegate {

    public let menu = NSMenu(title: "Main Menu")
    public let appCommands: AppCommands
    public private(set) var surface: MenuSurface = .browser

    /// Surface-specific items with their table key, so a hidden item can
    /// drop its key and get it back.
    private struct SurfaceItem {
        let item: NSMenuItem
        let placement: MenuPlacement
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }
    private var surfaceItems: [SurfaceItem] = []
    private var itemsByCommand: [ShrikeCommand: [NSMenuItem]] = [:]

    // Lazy submenus.
    private(set) var fileMenu = NSMenu(title: "File")
    private(set) var openRecentMenu = NSMenu(title: "Open Recent")
    private(set) var copyToMenu = NSMenu(title: "Copy to Folder")
    private(set) var moveToMenu = NSMenu(title: "Move to Folder")
    private(set) var editorsMenu = NSMenu(title: "Open in External Editor")
    private(set) var sortMenu = NSMenu(title: "Sort By")
    private(set) var windowMenu = NSMenu(title: "Window")
    private(set) var helpMenu = NSMenu(title: "Help")
    private(set) var servicesMenu = NSMenu(title: "Services")
    private var mainObserver: (any NSObjectProtocol)?
    /// Share ▸ in the File menu.
    private(set) lazy var shareSubmenu = ShareSubmenu(files: { [weak self] in
        self?.mainTarget()?.shareFileURLs ?? []
    })

    /// Where recent items come from (test seam).
    public var recentURLs: () -> [URL] = {
        AppCommands.recentURLs()
    }
    /// The window whose command state feeds Share ▸ and Sort By ▸.
    public var mainTarget: () -> (any ShrikeCommandTarget)? = {
        AppCommands.target(of: NSApp?.mainWindow)
    }

    /// Builds the whole bar (signpost `mainMenu`). Does not touch `NSApp`.
    public init(appCommands: AppCommands) {
        self.appCommands = appCommands
        super.init()
        let state = ShrikeSignposts.launch.begin("mainMenu")
        build()
        ShrikeSignposts.launch.end("mainMenu", state)
    }

    /// Installs the bar on `NSApp` and follows the main window.
    public func install(in app: NSApplication) {
        // No window tabs, so AppKit adds no
        // View ▸ Show Tab Bar / Show All Tabs. Set before any window.
        NSWindow.allowsAutomaticWindowTabbing = false
        app.mainMenu = menu
        app.windowsMenu = windowMenu
        app.helpMenu = helpMenu
        app.servicesMenu = servicesMenu
        mainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.apply(surface: MenuSurface.of(window)) }
        }
    }

    // MARK: Surface

    /// Shows the items of `surface` and hides (and un-keys) the others.
    /// `.other` keeps the last set.
    public func apply(surface newSurface: MenuSurface) {
        guard newSurface != .other else { return }
        surface = newSurface
        for entry in surfaceItems {
            let visible = entry.placement.isVisible(on: newSurface)
            entry.item.isHidden = !visible
            entry.item.keyEquivalent = visible ? entry.key : ""
            entry.item.keyEquivalentModifierMask = visible ? entry.modifiers : []
        }
        // Window, Help and Services get items from AppKit later: leave them.
        Self.tidySeparators(in: menu, skipping: [windowMenu, helpMenu, servicesMenu])
    }

    /// No empty groups: hides a separator that would lead,
    /// end or follow another one once the other surface's items are
    /// hidden. The viewer's Edit menu used to end on a separator (Find
    /// is Browser-only), and AppKit adds its own before AutoFill: two in
    /// a row. Walks submenus; cheap enough for every surface change.
    static func tidySeparators(in menu: NSMenu, skipping: [NSMenu] = []) {
        guard !skipping.contains(where: { $0 === menu }) else { return }
        var afterSeparator = true   // hides a leading separator
        var lastShown: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem {
                item.isHidden = afterSeparator
                if !item.isHidden { afterSeparator = true; lastShown = item }
            } else if !item.isHidden {
                afterSeparator = false
            }
            if let sub = item.submenu { tidySeparators(in: sub, skipping: skipping) }
        }
        if afterSeparator, let lastShown { lastShown.isHidden = true }
    }

    /// Items for `command` (tests, lazy fills).
    public func items(for command: ShrikeCommand) -> [NSMenuItem] {
        itemsByCommand[command] ?? []
    }

    /// Every item, submenus included.
    public var allItems: [NSMenuItem] {
        var out: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                out.append(item)
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        return out
    }

    // MARK: NSMenuDelegate (lazy fills)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        apply(surface: MenuSurface.of(NSApp?.mainWindow))
        applyIcons(opening: menu)   // before the hints: an icon changes the row width
        applyKeyHints(opening: menu)
        switch menu {
        case openRecentMenu: fillOpenRecent()
        case copyToMenu: fillDestinations(copyToMenu, command: .copyToFolder)
        case moveToMenu: fillDestinations(moveToMenu, command: .moveToFolder)
        case editorsMenu: fillEditors()
        case sortMenu: fillSortChecks()
        case fileMenu: fillShare()
        default: break
        }
    }

    func fillOpenRecent() {
        let menu = openRecentMenu
        menu.removeAllItems()
        let limit = max(0, Prefs.recentFoldersLimit)
        for url in recentURLs().prefix(limit) {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: url.path),
                action: #selector(AppCommands.openRecentItem(_:)), keyEquivalent: ""
            )
            item.target = appCommands
            item.representedObject = url
            item.toolTip = UserFacingPath.string(url)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""
        ))
    }

    /// "1  Selects" … "9  …", then "Choose Folder…".
    func fillDestinations(_ menu: NSMenu, command: ShrikeCommand) {
        Self.fillDestinations(menu, command: command, slots: .standard, target: nil)
    }

    /// The slot rows of a Copy / Move to Folder ▸ submenu (tag = slot,
    /// 0 = Choose Folder…). Shared by the File menu and the viewer's
    /// context menu. No key equivalents: a bare `C` / `M`
    /// must reach the chord.
    static func fillDestinations(_ menu: NSMenu, command: ShrikeCommand,
                                 slots: DestinationSlots, target: AnyObject?) {
        menu.removeAllItems()
        func row(_ title: String, tag: Int) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: commandAction, keyEquivalent: "")
            item.representedObject = command.rawValue
            item.target = target
            item.tag = tag
            return item
        }
        for (offset, slot) in slots.slots().enumerated() {
            guard let slot else { continue }
            menu.addItem(row("\(offset + 1)  \(slot.name)", tag: offset + 1))
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(row("Choose Folder…", tag: 0))
    }

    /// Open in External Editor ▸: the registry's editors
    /// with ⌥⌘1 … ⌥⌘9, then "Edit External Editors…".
    func fillEditors() {
        ExternalEditors.fill(editorsMenu, target: nil)
    }

    func fillSortChecks() {
        let target = mainTarget()
        for item in sortMenu.items {
            if let command = item.shrikeCommand {
                item.state = target?.menuState(for: command) ?? .off
            } else if item.action == #selector(BrowserWindowController.setSortDirection(_:)) {
                item.state = (target as? BrowserWindowController)?.sortDirectionState(tag: item.tag) ?? .off
            }
        }
    }

    /// Share ▸: enabled with a submenu when the main window has files
    /// to share; the services are listed when the submenu opens.
    func fillShare() {
        shareSubmenu.refreshParent()
    }

    // MARK: Build

    private func build() {
        menu.addItem(submenuItem(makeAppMenu()))
        menu.addItem(submenuItem(makeFileMenu()))
        menu.addItem(submenuItem(makeEditMenu()))
        menu.addItem(submenuItem(makeViewMenu()))
        menu.addItem(submenuItem(makeImageMenu()))
        menu.addItem(submenuItem(makeGoMenu()))
        menu.addItem(submenuItem(windowMenuBuilt()))
        menu.addItem(submenuItem(helpMenuBuilt()))
        apply(surface: surface)
        // The hints are NOT drawn here: that cost ~4 ms of the `mainMenu`
        // launch signpost. Each top-level menu draws its own the first time
        // it opens (`menuNeedsUpdate`), and again after a preset switch
        // (spec 25 §13.1).
        for item in menu.items {
            guard let sub = item.submenu, sub !== servicesMenu, sub !== windowMenu, sub !== helpMenu,
                  sub.items.contains(where: { $0.shrikeCommand != nil || $0.submenu != nil }) else { continue }
            if sub.delegate == nil { sub.delegate = self }
            hintMenus.append(sub)
        }
        // The Window menu draws no hints but carries the Welcome icon (spec 27 P3-9).
        if windowMenu.delegate == nil { windowMenu.delegate = self }
        presetObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hintedMenus.isEmpty,
                      self.hintedPreset != ShortcutTable.livePreset else { return }
                // Redraw the menus that were opened; the others draw when they open.
                self.hintedMenus.removeAll()
                self.hintedPreset = nil
            }
        }
    }

    private var presetObserver: (any NSObjectProtocol)?
    private var hintedPreset: ShortcutPreset?
    /// The top-level menus that can show hints, and those already drawn for `hintedPreset`.
    private var hintMenus: [NSMenu] = []
    private var hintedMenus: Set<ObjectIdentifier> = []

    /// Items that have their own key on some surface: they get no hint
    /// (hidden ones have their key removed for now).
    private var keyedItems: Set<ObjectIdentifier> {
        Set(surfaceItems.filter { !$0.key.isEmpty }.map { ObjectIdentifier($0.item) })
    }

    /// Bare keys drawn in the titles (display only). Draws every menu that
    /// has not been drawn for the live preset (tests, preset switch).
    func applyKeyHints() {
        let preset = ShortcutTable.livePreset
        if hintedPreset != preset { hintedMenus.removeAll() }
        hintedPreset = preset
        let keyed = keyedItems
        for sub in hintMenus where !hintedMenus.contains(ObjectIdentifier(sub)) {
            MenuKeyHints.apply(to: sub, context: .viewer, preset: preset,
                               hasOwnKey: { !$0.keyEquivalent.isEmpty || keyed.contains(ObjectIdentifier($0)) })
            hintedMenus.insert(ObjectIdentifier(sub))
        }
    }

    /// Draws the hints of one top-level menu, once per preset.
    private func applyKeyHints(opening opened: NSMenu) {
        guard hintMenus.contains(where: { $0 === opened }) else { return }
        let preset = ShortcutTable.livePreset
        if hintedPreset != preset { hintedMenus.removeAll(); hintedPreset = preset }
        guard !hintedMenus.contains(ObjectIdentifier(opened)) else { return }
        let keyed = keyedItems
        MenuKeyHints.apply(to: opened, context: .viewer, preset: preset,
                           hasOwnKey: { !$0.keyEquivalent.isEmpty || keyed.contains(ObjectIdentifier($0)) })
        hintedMenus.insert(ObjectIdentifier(opened))
    }

    // MARK: Menu icons (spec 27 P3-9)

    /// Whether the system draws icons on its own standard items. macOS 26 does (Copy,
    /// Paste, Select All, ...), so our items beside them get one too, or the labels
    /// of one menu start at two different places. Tests set it to try both.
    nonisolated(unsafe) static var systemDrawsMenuIcons: Bool = {
        if #available(macOS 26, *) { return true }
        return false
    }()

    /// The icon of each Shrike item in a menu that shows icons (Shrike, File, Edit, View, Window).
    /// A menu is all icons or none, so View lists every one of its rows.
    static let menuIconTable: [(command: ShrikeCommand, symbol: String)] = [
        (.copyPath, "link"), (.deselectAll, "rectangle.dashed"),                   // Edit
        (.viewAsGrid, "square.grid.2x2"), (.viewAsFilmstrip, "film"),              // View
        (.viewAsList, "list.bullet"), (.filter, "line.3.horizontal.decrease"),
        (.largerThumbnails, "arrow.up.left.and.arrow.down.right"),
        (.smallerThumbnails, "arrow.down.right.and.arrow.up.left"),
        (.zoomIn, "plus.magnifyingglass"), (.zoomOut, "minus.magnifyingglass"),
        (.zoomToFit, "arrow.up.left.and.down.right.magnifyingglass"),
        (.actualSize, "1.magnifyingglass"), (.zoom200, "magnifyingglass"),
        (.zoom300, "magnifyingglass"), (.fitWidth, "arrow.left.and.right"),
        (.fitHeight, "arrow.up.and.down"), (.loupe, "magnifyingglass.circle"),
        (.toggleSidebar, "sidebar.left"), (.toggleToolbar, "menubar.rectangle"),
        (.toggleInspector, "sidebar.right"),
        (.toggleFilmstrip, "film.stack"), (.toggleHistogram, "chart.bar"),
        (.unpinAllPanels, "pin.slash"), (.slideshow, "play.rectangle"),
        (.compare, "rectangle.split.2x1"), (.toggleFullScreen, "arrow.up.left.and.arrow.down.right.circle"),
        (.welcome, "macwindow"),                                                   // Window
        (.settings, "gearshape"),                                                  // Shrike
        (.newBrowserWindow, "macwindow.badge.plus"), (.open, "doc"),               // File
        (.openFolder, "folder"), (.save, "square.and.arrow.down"),
        (.saveAs, "square.and.arrow.down.on.square"), (.revertToOriginal, "arrow.uturn.backward"),
        (.rename, "pencil"), (.copyToFolder, "doc.on.doc"), (.moveToFolder, "arrowshape.turn.up.right"),
        (.tags, "tag"), (.addToFavorites, "star"), (.revealInFinder, "arrow.up.forward.app"),
        (.share, "square.and.arrow.up"), (.openExternalEditor1, "square.and.pencil"),
        (.moveToTrash, "trash"), (.pageSetup, "doc.plaintext"), (.print, "printer"),
        (.exportContactSheet, "square.grid.3x3"),
    ]

    /// Submenu rows that are not commands, by title: they carry an icon like their neighbours.
    static let menuHolderIconTable: [(title: String, symbol: String)] = [
        ("Services", "gearshape.2"),            // Shrike
        ("Open Recent", "clock"),               // File
        ("Find", "magnifyingglass"),            // Edit
        ("Sort By", "arrow.up.arrow.down"),     // View
    ]

    private var iconedMenus: Set<ObjectIdentifier> = []

    /// Sets (or, where a symbol is missing or the system draws none, clears) the icons of
    /// the table's items in `menu`. One menu is all icons or none, never a mix.
    private func applyIcons(opening menu: NSMenu) {
        guard !iconedMenus.contains(ObjectIdentifier(menu)) else { return }
        iconedMenus.insert(ObjectIdentifier(menu))
        var rows = Self.menuIconTable.flatMap { entry in
            (itemsByCommand[entry.command] ?? []).filter { $0.menu === menu }.map { ($0, entry.symbol) }
        }
        for holder in Self.menuHolderIconTable {
            rows += menu.items.filter { $0.submenu != nil && $0.title == holder.title }.map { ($0, holder.symbol) }
        }
        guard !rows.isEmpty else { return }
        let draws = Self.systemDrawsMenuIcons
        let images = rows.map { draws ? NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) : nil }
        let complete = draws && !images.contains { $0 == nil }
        for (n, row) in rows.enumerated() { row.0.image = complete ? images[n] : nil }
    }

    /// Every menu now (tests).
    func applyAllIconsForTesting() {
        iconedMenus.removeAll()
        for item in menu.items { if let sub = item.submenu { applyIcons(opening: sub) } }
    }

    private func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The selector every window command item sends.
    public static let commandAction = NSSelectorFromString("performShrikeCommand:")

    /// An item for `command`, keyed from the table.
    private func makeCommandItem(
        _ command: ShrikeCommand, title: String? = nil,
        action: Selector = ShrikeMainMenu.commandAction, withKey: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? command.title, action: action, keyEquivalent: "")
        item.representedObject = command.rawValue
        if withKey, let binding = ShortcutTable.menuBinding(for: command),
           let key = binding.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = binding.modifiers
        }
        return item
    }

    @discardableResult
    private func add(
        _ command: ShrikeCommand, to menu: NSMenu, _ placement: MenuPlacement = .both,
        action: Selector = ShrikeMainMenu.commandAction, target: AnyObject? = nil,
        title: String? = nil
    ) -> NSMenuItem {
        let item = makeCommandItem(command, title: title, action: action)
        item.target = target
        register(item, command: command, placement: placement)
        menu.addItem(item)
        return item
    }

    private func register(_ item: NSMenuItem, command: ShrikeCommand?, placement: MenuPlacement) {
        if let command { itemsByCommand[command, default: []].append(item) }
        if placement != .both {
            surfaceItems.append(SurfaceItem(
                item: item, placement: placement,
                key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask
            ))
        }
    }

    private func addSubmenu(
        _ submenu: NSMenu, to menu: NSMenu, command: ShrikeCommand? = nil,
        _ placement: MenuPlacement = .both, lazy: Bool = false
    ) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        if let command { item.representedObject = command.rawValue }
        if lazy { submenu.delegate = self }
        register(item, command: command, placement: placement)
        menu.addItem(item)
    }

    private func makeAppMenu() -> NSMenu {
        let m = NSMenu(title: "Shrike")
        m.addItem(withTitle: "About Shrike",
                  action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        add(.settings, to: m, action: #selector(AppCommands.showSettings(_:)), target: appCommands)
        m.addItem(.separator())
        addSubmenu(servicesMenu, to: m)
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Shrike", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = m.addItem(withTitle: "Hide Others",
                                   action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Shrike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    private func makeFileMenu() -> NSMenu {
        let m = fileMenu
        m.delegate = self
        add(.newBrowserWindow, to: m, action: #selector(AppCommands.newBrowserWindow(_:)), target: appCommands)
        add(.open, to: m, action: #selector(AppCommands.openFiles(_:)), target: appCommands)
        add(.openFolder, to: m, action: #selector(AppCommands.openFolder(_:)), target: appCommands)
        addSubmenu(openRecentMenu, to: m, lazy: true)
        m.addItem(.separator())
        add(.close, to: m, action: #selector(NSWindow.performClose(_:)))
        add(.save, to: m, .viewer)
        add(.saveAs, to: m, .viewer)
        add(.revertToOriginal, to: m)
        m.addItem(.separator())
        add(.rename, to: m)
        addSubmenu(copyToMenu, to: m, command: .copyToFolder, lazy: true)
        addSubmenu(moveToMenu, to: m, command: .moveToFolder, lazy: true)
        add(.tags, to: m)
        add(.addToFavorites, to: m, .browser)
        add(.revealInFinder, to: m)
        // Share ▸; `fillShare()` enables it when the File menu opens.
        let share = shareSubmenu.makeParentItem()
        register(share, command: .share, placement: .both)
        m.addItem(share)
        addSubmenu(editorsMenu, to: m, command: .openExternalEditor1, lazy: true)
        m.addItem(.separator())
        add(.moveToTrash, to: m)
        m.addItem(.separator())
        add(.pageSetup, to: m)
        add(.print, to: m)
        add(.exportContactSheet, to: m, .browser)
        return m
    }

    /// AppKit adds Writing Tools items to the Edit menu,
    /// which loads WritingToolsUI at launch (~96 ms measured in a trace).
    /// An image viewer has no text to rewrite; Cut / Copy / Paste /
    /// Select All are Shrike's own items and stay. Tests flip it to measure.
    nonisolated(unsafe) static var insertsWritingToolsItems = false

    private func makeEditMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        if #available(macOS 15.2, *) {
            m.automaticallyInsertsWritingToolsItems = Self.insertsWritingToolsItems
        }
        add(.undo, to: m, action: NSSelectorFromString("undo:"))
        add(.redo, to: m, action: NSSelectorFromString("redo:"))
        m.addItem(.separator())
        add(.cut, to: m, action: #selector(NSText.cut(_:)))
        add(.copy, to: m, action: #selector(NSText.copy(_:)))
        add(.copyPath, to: m)
        add(.paste, to: m, action: #selector(NSText.paste(_:)))
        add(.selectAll, to: m, action: #selector(NSText.selectAll(_:)))
        add(.deselectAll, to: m, .browser)
        m.addItem(.separator())
        let find = NSMenu(title: "Find")
        add(.find, to: find, .browser)
        addSubmenu(find, to: m, .browser)
        return m
    }

    private func makeViewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        add(.viewAsGrid, to: m, .browser)
        add(.viewAsFilmstrip, to: m, .browser)
        add(.viewAsList, to: m, .browser)
        for command in [ShrikeCommand.sortByName, .sortByDateCaptured, .sortByDateModified,
                        .sortBySize, .sortByRating, .sortByKind, .sortByDimensions] {
            add(command, to: sortMenu, .browser)
        }
        sortMenu.addItem(.separator())
        for (tag, title) in [(0, "Ascending"), (1, "Descending")] {
            let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.setSortDirection(_:)),
                                  keyEquivalent: "")
            item.tag = tag
            sortMenu.addItem(item)
        }
        addSubmenu(sortMenu, to: m, .browser, lazy: true)
        add(.filter, to: m, .browser)
        add(.largerThumbnails, to: m, .browser)
        add(.smallerThumbnails, to: m, .browser)
        add(.zoomIn, to: m, .viewer)
        add(.zoomOut, to: m, .viewer)
        add(.zoomToFit, to: m, .viewer)
        add(.actualSize, to: m, .viewer)
        add(.zoom200, to: m, .viewer)
        add(.zoom300, to: m, .viewer)
        add(.fitWidth, to: m, .viewer)
        add(.fitHeight, to: m, .viewer)
        add(.loupe, to: m, .viewer)
        m.addItem(.separator())
        add(.toggleSidebar, to: m, .browser)
        add(.toggleToolbar, to: m, action: #selector(NSWindow.toggleToolbarShown(_:)))
        add(.customizeToolbar, to: m, action: #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        add(.toggleInspector, to: m)
        add(.toggleFilmstrip, to: m, .viewer)
        add(.toggleHistogram, to: m, .viewer)
        add(.unpinAllPanels, to: m, .viewer)
        m.addItem(.separator())
        add(.slideshow, to: m)
        add(.compare, to: m)
        add(.toggleFullScreen, to: m, .viewer, action: #selector(NSWindow.toggleFullScreen(_:)))
        return m
    }

    private func makeImageMenu() -> NSMenu {
        let m = NSMenu(title: "Image")
        add(.rotateLeft, to: m)
        add(.rotateRight, to: m)
        add(.rotate180, to: m)
        add(.flipHorizontal, to: m)
        add(.flipVertical, to: m)
        m.addItem(.separator())
        let rating = NSMenu(title: "Rating")
        for command in [ShrikeCommand.rate0, .rate1, .rate2, .rate3, .rate4, .rate5] {
            add(command, to: rating)
        }
        addSubmenu(rating, to: m)
        add(.toggleFlag, to: m)
        m.addItem(.separator())
        add(.editImage, to: m, .viewer)
        let tools = NSMenu(title: "Edit Tools")
        for command in [ShrikeCommand.editCrop, .editRotate, .editResize, .editColor] {
            add(command, to: tools, .viewer)
        }
        addSubmenu(tools, to: m, .viewer)
        add(.resetEdits, to: m, .viewer)
        add(.levels, to: m, .viewer)
        add(.autoContrast, to: m, .viewer)
        add(.autoColor, to: m, .viewer)
        add(.toggleRAWFile, to: m)
        m.addItem(.separator())
        add(.batch, to: m)
        add(.showInMaps, to: m)
        return m
    }

    private func makeGoMenu() -> NSMenu {
        let m = NSMenu(title: "Go")
        add(.nextImage, to: m)
        add(.previousImage, to: m)
        add(.firstImage, to: m)
        add(.lastImage, to: m)
        m.addItem(.separator())
        add(.nextFolder, to: m)
        add(.previousFolder, to: m)
        add(.enclosingFolder, to: m, .browser)
        add(.back, to: m, .browser)
        add(.forward, to: m, .browser)
        add(.goToFolder, to: m)
        m.addItem(.separator())
        add(.showInBrowser, to: m, .viewer)
        return m
    }

    private func windowMenuBuilt() -> NSMenu {
        let m = windowMenu
        add(.minimize, to: m, action: #selector(NSWindow.performMiniaturize(_:)))
        m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        m.addItem(.separator())
        add(.welcome, to: m, action: #selector(AppCommands.showWelcome(_:)), target: appCommands)
        m.addItem(.separator())
        m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return m
    }

    private func helpMenuBuilt() -> NSMenu {
        add(.keyboardShortcuts, to: helpMenu,
            action: #selector(AppCommands.showKeyboardShortcuts(_:)), target: appCommands)
        return helpMenu
    }
}

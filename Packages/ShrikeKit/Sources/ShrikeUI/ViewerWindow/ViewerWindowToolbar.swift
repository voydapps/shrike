//
//  ViewerWindowToolbar.swift
//  ShrikeUI
//
//  The windowed viewer's NSToolbar. Built once per window;
//  every item sends an `ShrikeCommand` to the window, so the toolbar, the
//  menus and the keys run one path and grey out by one rule
//  (`canPerform`). Tooltips come from the shortcut resolver:
//  "<Title>  ·  <key>".
//
//  Edit mode swaps a different toolbar into `window.toolbar`
//  (`EditToolbarController`) and puts this one back after.
//

import AppKit
import ShrikeCore

/// What the toolbar asks of its window.
@MainActor
protocol ViewerToolbarHost: AnyObject {
    func canPerform(_ command: ShrikeCommand) -> Bool
    func perform(_ command: ShrikeCommand)
    func menuState(for command: ShrikeCommand) -> NSControl.StateValue
    /// First line of the Zoom menu: "Fit (42 %)" or "200 %".
    var toolbarZoomLine: String { get }
    /// The displayed file (Share).
    var toolbarShareURLs: [URL] { get }
    var toolbarInspectorShown: Bool { get }
    /// The zoom as the HUD shows it (`pixelScale` × 100, rounded); nil
    /// with no photo on screen.
    var toolbarZoomPercent: Int? { get }
    /// Whether the thing a toggle item switches is on.
    func toolbarToggleIsOn(_ command: ShrikeCommand) -> Bool
}

/// A toolbar toggle (flag, inspector, histogram, filmstrip, full screen)
/// drawn as the item's own view, so VoiceOver reads its state: the value
/// is "On" or "Off". An image-only `NSToolbarItem` can't carry an
/// accessibility value (its viewer doesn't list AXValue). The `.toggle`
/// type keeps the plain toolbar-button look (no pressed bezel when on);
/// `isOn` follows the host on every validation pass.
@MainActor
final class ToolbarToggleButton: NSButton {

    final class Cell: NSButtonCell {
        override func accessibilityValue() -> Any? {
            state == .on ? ToolbarToggleButton.onValue : ToolbarToggleButton.offValue
        }
    }

    static let onValue = "On"
    static let offValue = "Off"

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    let command: ShrikeCommand

    init(command: ShrikeCommand, image: NSImage, label: String) {
        self.command = command
        super.init(frame: .zero)
        setButtonType(.toggle)
        bezelStyle = .toolbar
        isBordered = true
        title = ""
        self.image = image
        // The system toolbar button's own settings (checked against a
        // plain image item offscreen, ToolbarItemLookTests). Set after the
        // image: assigning it moves an empty-title button to "overlaps".
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isOn: Bool {
        get { state == .on }
        set { if isOn != newValue { state = newValue ? .on : .off } }
    }
}

@MainActor
final class ViewerWindowToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation,
                                 NSSharingServicePickerToolbarItemDelegate {

    static let identifier = NSToolbar.Identifier("shrike.viewer.toolbar.v3")

    enum ID {
        static let nav = NSToolbarItem.Identifier("shrike.viewer.nav")
        static let zoom = NSToolbarItem.Identifier("shrike.viewer.zoom")
        static let rotate = NSToolbarItem.Identifier("shrike.viewer.rotate")
        static let rating = NSToolbarItem.Identifier("shrike.viewer.rating")
        static let flag = NSToolbarItem.Identifier("shrike.viewer.flag")
        static let share = NSToolbarItem.Identifier("shrike.viewer.share")
        static let edit = NSToolbarItem.Identifier("shrike.viewer.edit")
        static let trash = NSToolbarItem.Identifier("shrike.viewer.trash")
        static let inspector = NSToolbarItem.Identifier("shrike.viewer.inspector")
        // Optional (Customize Toolbar palette only).
        static let slideshow = NSToolbarItem.Identifier("shrike.viewer.slideshow")
        static let fullScreen = NSToolbarItem.Identifier("shrike.viewer.fullScreen")
        static let histogram = NSToolbarItem.Identifier("shrike.viewer.histogram")
        static let filmstrip = NSToolbarItem.Identifier("shrike.viewer.filmstrip")
        static let showInBrowser = NSToolbarItem.Identifier("shrike.viewer.showInBrowser")
        static let reveal = NSToolbarItem.Identifier("shrike.viewer.reveal")
        static let copyTo = NSToolbarItem.Identifier("shrike.viewer.copyTo")
        static let moveTo = NSToolbarItem.Identifier("shrike.viewer.moveTo")
        static let tags = NSToolbarItem.Identifier("shrike.viewer.tags")
        static let zoomToFit = NSToolbarItem.Identifier("shrike.viewer.zoomToFit")
        static let actualSize = NSToolbarItem.Identifier("shrike.viewer.actualSize")
    }

    /// The 14 default items, left to right (spec 24 §3.1: Show in Browser
    /// after the nav group; Histogram, then Full Screen, before the
    /// tracking separator and the Inspector). The
    /// identifier carries a version so a stored configuration of the old
    /// set cannot hide them.
    static let defaultItems: [NSToolbarItem.Identifier] = [
        ID.nav, ID.showInBrowser, .flexibleSpace, ID.zoom, ID.rotate, ID.rating, ID.flag, ID.share,
        ID.edit, ID.trash, ID.histogram, ID.fullScreen, .inspectorTrackingSeparator, ID.inspector,
    ]

    /// Overflow order when the window is narrow (spec 24 §3.1): nav, Show
    /// in Browser and the inspector stay longest; Histogram goes first.
    static func visibilityPriority(_ id: NSToolbarItem.Identifier) -> NSToolbarItem.VisibilityPriority {
        switch id {
        case ID.nav, ID.showInBrowser, ID.inspector: return .high
        case ID.histogram: return .low
        default: return .standard
        }
    }

    /// Optional single-command buttons: identifier, symbol, label, command.
    static let optionalButtons: [(NSToolbarItem.Identifier, String, String, ShrikeCommand)] = [
        (ID.slideshow, "play.rectangle", "Slideshow", .slideshow),
        (ID.filmstrip, "rectangle.bottomthird.inset.filled", "Filmstrip", .toggleFilmstrip),
        (ID.reveal, "folder", "Reveal in Finder", .revealInFinder),
        (ID.copyTo, "doc.on.doc", "Copy to Folder", .copyToFolder),
        (ID.moveTo, "folder.badge.plus", "Move to Folder", .moveToFolder),
        (ID.tags, "tag", "Tags", .tags),
        (ID.zoomToFit, "arrow.up.left.and.down.right.magnifyingglass", "Zoom to Fit", .zoomToFit),
        (ID.actualSize, "1.magnifyingglass", "Actual Size", .actualSize),
    ]

    /// Default single-command buttons (flag and inspector change glyph).
    private static let defaultButtons: [(NSToolbarItem.Identifier, String, String, ShrikeCommand)] = [
        (ID.showInBrowser, "square.grid.2x2", "Show in Browser", .showInBrowser),
        (ID.flag, "flag", "Flag", .toggleFlag),
        (ID.histogram, "chart.bar.xaxis", "Histogram", .toggleHistogram),
        (ID.fullScreen, "arrow.up.left.and.arrow.down.right", "Enter Full Screen", .toggleFullScreen),
        (ID.edit, "slider.horizontal.3", "Edit", .editImage),
        (ID.trash, "trash", "Delete", .moveToTrash),
        (ID.inspector, "info.circle", "Inspector", .toggleInspector),
    ]

    /// Items drawn by a `ToolbarToggleButton`, and the command each sends.
    static let toggleCommands: [NSToolbarItem.Identifier: ShrikeCommand] = [
        ID.flag: .toggleFlag, ID.inspector: .toggleInspector, ID.histogram: .toggleHistogram,
        ID.filmstrip: .toggleFilmstrip, ID.fullScreen: .toggleFullScreen,
    ]

    /// Zoom menu rows after the current-value line (nil = separator).
    static let zoomRows: [ShrikeCommand?] = [
        .zoomIn, .zoomOut, nil, .zoomToFit, .actualSize, .zoom200, .zoom300, nil, .fitWidth, .fitHeight,
        nil, .toggleHistogram,
    ]
    static let ratingCommands: [ShrikeCommand] = [.rate0, .rate1, .rate2, .rate3, .rate4, .rate5]

    let toolbar: NSToolbar
    weak var host: (any ViewerToolbarHost)?
    /// Items built once; `toolbar(_:itemForItemIdentifier:…)` hands them
    /// out (a palette copy gets a fresh item).
    private var built: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    /// Why Edit is off, shown under the Edit item's tooltip.
    private var editExtraLine: String?
    private var shownFlag: Bool?
    private var shownRating: Int?
    /// The Zoom item's last accessibility value (outer nil = never set).
    private var shownZoomValue: String??
    /// The Zoom pull-down's menu. Row 0 is the button's glyph (a pull-down
    /// never lists its first row).
    let zoomMenu = NSMenu(title: "Zoom")
    /// The same rows for the toolbar's overflow menu and text-only mode.
    let zoomOverflowMenu = NSMenu(title: "Zoom")
    /// The Rating pull-down's menu. Row 0 is the button's glyph.
    let ratingMenu = NSMenu(title: "Rating")
    /// The same rows for the overflow menu and text-only mode.
    let ratingOverflowMenu = NSMenu(title: "Rating")
    /// The Rating button's glyph (`star` / yellow `star.fill`).
    private var ratingGlyph: NSImage?

    init(host: (any ViewerToolbarHost)?) {
        self.host = host
        toolbar = NSToolbar(identifier: Self.identifier)
        super.init()
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = self
        zoomMenu.delegate = self
        zoomOverflowMenu.delegate = self
        ratingMenu.delegate = self
        ratingOverflowMenu.delegate = self
        zoomMenu.autoenablesItems = false
        zoomOverflowMenu.autoenablesItems = false
        ratingMenu.autoenablesItems = false
        ratingOverflowMenu.autoenablesItems = false
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems + Self.optionalButtons.map(\.0) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if flag, let item = built[itemIdentifier] { return item }
        guard let item = makeItem(itemIdentifier) else { return nil }
        item.visibilityPriority = Self.visibilityPriority(itemIdentifier)
        if flag { built[itemIdentifier] = item }
        return item
    }

    /// The second tooltip line of the Edit item (nil: none).
    func setEditExtraLine(_ line: String?) {
        editExtraLine = line
        if let item = item(ID.edit) { LiveTooltips.shared.setExtraLine(line, on: item) }
    }

    /// The item for `id` as the toolbar shows it (tests, validation).
    func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier == id } ?? built[id]
    }

    private func tip(_ command: ShrikeCommand) -> String {
        ShortcutTable.tooltip(for: command, context: .viewer)
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    private func makeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch id {
        case ID.nav:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("chevron.left", "Previous"), symbol("chevron.right", "Next")],
                selectionMode: .momentary, labels: ["Previous", "Next"],
                target: self, action: #selector(navGroup(_:)))
            group.isNavigational = true
            group.label = "Previous / Next"
            group.paletteLabel = "Previous / Next"
            group.subitems[0].toolTip = tip(.previousImage)
            group.subitems[1].toolTip = tip(.nextImage)
            group.subitems[0].label = "Previous"
            group.subitems[1].label = "Next"
            group.menuFormRepresentation = submenuRow(
                "Previous / Next", symbol: "chevron.left.chevron.right",
                rows: [(.previousImage, "Previous", "chevron.left"), (.nextImage, "Next", "chevron.right")])
            group.autovalidates = false
            return group
        case ID.rotate:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("rotate.left", "Rotate Left"), symbol("rotate.right", "Rotate Right")],
                selectionMode: .momentary, labels: ["Rotate Left", "Rotate Right"],
                target: self, action: #selector(rotateGroup(_:)))
            group.label = "Rotate"
            group.paletteLabel = "Rotate"
            group.subitems[0].toolTip = tip(.rotateLeft)
            group.subitems[1].toolTip = tip(.rotateRight)
            group.menuFormRepresentation = submenuRow(
                "Rotate", symbol: "rotate.right",
                rows: [(.rotateLeft, "Rotate Left", "rotate.left"), (.rotateRight, "Rotate Right", "rotate.right")])
            group.autovalidates = false
            return group
        case ID.zoom:
            // A pull-down as the item's view (not NSMenuToolbarItem), so
            // VoiceOver reads the zoom as the item's value.
            let item = NSToolbarItem(itemIdentifier: id)
            // Looks and sizes like `NSMenuToolbarItem` with
            // `showsIndicator = true`: arrow at the bottom, image only
            // (checked offscreen, ToolbarItemLookTests).
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.bezelStyle = .toolbar
            if zoomMenu.items.isEmpty { zoomMenu.addItem(zoomGlyphRow()) }
            button.menu = zoomMenu
            button.imagePosition = .imageOnly
            (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            // Rows are enabled by the menu rule in menuNeedsUpdate, never
            // re-enabled by the pop-up's own validation.
            button.autoenablesItems = false
            button.toolTip = "Zoom"
            button.setAccessibilityLabel("Zoom")
            item.view = button
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
            item.toolTip = "Zoom"
            let overflow = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
            overflow.image = symbol("plus.magnifyingglass", "Zoom")
            overflow.submenu = zoomOverflowMenu
            item.menuFormRepresentation = overflow
            item.autovalidates = false
            shownZoomValue = nil
            return item
        case ID.rating:
            // A pull-down as the item's view, like Zoom, so VoiceOver reads
            // "3 stars" / "No rating" as the value.
            // Looks like `NSMenuToolbarItem` with `showsIndicator = false`
            // (ToolbarItemLookTests).
            let item = NSToolbarItem(itemIdentifier: id)
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.bezelStyle = .toolbar
            if ratingMenu.items.isEmpty { ratingMenu.addItem(ratingGlyphRow()) }
            button.menu = ratingMenu
            button.imagePosition = .imageOnly
            (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            button.autoenablesItems = false
            button.setAccessibilityLabel("Rating")
            button.setAccessibilityValue(Self.ratingValue(0))
            item.view = button
            item.label = "Rating"
            item.paletteLabel = "Rating"
            let overflow = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
            overflow.image = symbol("star", "Rating")
            overflow.submenu = ratingOverflowMenu
            item.menuFormRepresentation = overflow
            item.autovalidates = false
            shownRating = nil
            return item
        case ID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.toolTip = "Share"
            item.delegate = self
            item.autovalidates = false
            return item
        default:
            let all = Self.defaultButtons + Self.optionalButtons
            guard let (_, name, label, command) = all.first(where: { $0.0 == id }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            if Self.toggleCommands[id] != nil {
                let button = ToolbarToggleButton(command: command, image: symbol(name, label), label: label)
                button.target = self
                button.action = #selector(toggleButton(_:))
                button.toolTip = tip(command)
                item.view = button
                item.label = label
                item.paletteLabel = label
                item.toolTip = tip(command)
                // The » row: the same glyph, and a check mark while on
                // (`applyToggle`, `validateMenuItem`).
                item.menuFormRepresentation = commandRow(command, title: label, symbol: name)
                item.autovalidates = false
                if id == ID.flag { shownFlag = nil }
                return item
            }
            item.image = symbol(name, label)
            item.label = label
            item.paletteLabel = label
            if id == ID.edit {
                // Live key text, plus a second line when Edit is off (spec 26 §2).
                LiveTooltips.shared.bind(item, command: command, context: .viewer)
                LiveTooltips.shared.setExtraLine(editExtraLine, on: item)
            } else {
                item.toolTip = tip(command)
            }
            item.target = self
            item.action = #selector(buttonItem(_:))
            item.isBordered = true
            item.autovalidates = false
            return item
        }
    }

    // MARK: Actions

    @objc private func navGroup(_ sender: NSToolbarItemGroup) {
        host?.perform(sender.selectedIndex == 0 ? .previousImage : .nextImage)
    }

    @objc private func rotateGroup(_ sender: NSToolbarItemGroup) {
        host?.perform(sender.selectedIndex == 0 ? .rotateLeft : .rotateRight)
    }

    @objc private func buttonItem(_ sender: NSToolbarItem) {
        let all = Self.defaultButtons + Self.optionalButtons
        guard let command = all.first(where: { $0.0 == sender.itemIdentifier })?.3 else { return }
        host?.perform(command)
    }

    @objc private func toggleButton(_ sender: ToolbarToggleButton) {
        host?.perform(sender.command)
        // The host's state wins over the click's own flip.
        if let host { sender.isOn = host.toolbarToggleIsOn(sender.command) }
    }

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = ShrikeCommand(rawValue: raw) else { return }
        host?.perform(command)
    }

    // MARK: Validation (the same rule as the menu items)

    /// Greys items out and refreshes the stateful glyphs. Called from the
    /// window's `update()`, once per event-loop pass.
    func validate() {
        guard let host else { return }
        for item in toolbar.items {
            switch item.itemIdentifier {
            case ID.nav:
                guard let group = item as? NSToolbarItemGroup, group.subitems.count == 2 else { continue }
                group.subitems[0].isEnabled = host.canPerform(.previousImage)
                group.subitems[1].isEnabled = host.canPerform(.nextImage)
                group.isEnabled = group.subitems.contains { $0.isEnabled }
            case ID.rotate:
                guard let group = item as? NSToolbarItemGroup, group.subitems.count == 2 else { continue }
                group.subitems[0].isEnabled = host.canPerform(.rotateLeft)
                group.subitems[1].isEnabled = host.canPerform(.rotateRight)
                group.isEnabled = group.subitems.contains { $0.isEnabled }
            case ID.zoom:
                item.isEnabled = host.canPerform(.zoomToFit)
                if let control = item.view as? NSControl, control.isEnabled != item.isEnabled {
                    control.isEnabled = item.isEnabled
                }
                let value = host.toolbarZoomPercent.map { "\($0) %" }
                if shownZoomValue != .some(value) {
                    shownZoomValue = .some(value)
                    item.view?.setAccessibilityValue(value)
                }
            case ID.rating:
                item.isEnabled = host.canPerform(.rate0)
                if let control = item.view as? NSControl, control.isEnabled != item.isEnabled {
                    control.isEnabled = item.isEnabled
                }
                applyRating(to: item, host: host)
            case ID.share:
                item.isEnabled = host.canPerform(.share)
            case ID.flag:
                applyToggle(item, command: .toggleFlag, host: host)
                let flagged = host.menuState(for: .toggleFlag) == .on
                if shownFlag != flagged {
                    shownFlag = flagged
                    let image = symbol(flagged ? "flag.fill" : "flag", "Flag")
                    let glyph = flagged ? image.withSymbolConfiguration(.init(paletteColors: [Badges.flagColor])) ?? image : image
                    if let button = item.view as? NSButton { button.image = glyph } else { item.image = glyph }
                    item.menuFormRepresentation?.image = glyph
                }
            case ID.inspector:
                applyToggle(item, command: .toggleInspector, host: host)
                let shown = host.toolbarInspectorShown
                let key = ShortcutTable.tooltip(for: .toggleInspector, context: .viewer)
                    .replacingOccurrences(of: "Show Inspector", with: shown ? "Hide Inspector" : "Show Inspector")
                if item.toolTip != key {
                    item.toolTip = key
                    item.view?.toolTip = key
                }
            default:
                if let command = Self.toggleCommands[item.itemIdentifier] {
                    applyToggle(item, command: command, host: host)
                    continue
                }
                let all = Self.defaultButtons + Self.optionalButtons
                if let command = all.first(where: { $0.0 == item.itemIdentifier })?.3 {
                    item.isEnabled = host.canPerform(command)
                }
            }
        }
    }

    /// Enabled by the menu rule; on / off from the host.
    private func applyToggle(_ item: NSToolbarItem, command: ShrikeCommand, host: any ViewerToolbarHost) {
        let enabled = host.canPerform(command)
        if item.isEnabled != enabled { item.isEnabled = enabled }
        let on = host.toolbarToggleIsOn(command)
        if let row = item.menuFormRepresentation {
            let state: NSControl.StateValue = on ? .on : .off
            if row.state != state { row.state = state }
            if row.isEnabled != enabled { row.isEnabled = enabled }
        }
        guard let button = item.view as? ToolbarToggleButton else { return }
        if button.isEnabled != enabled { button.isEnabled = enabled }
        button.isOn = on
        if command == .toggleHistogram { applyHistogramLook(item, button: button, on: on) }
    }

    /// Spec 24 §3.1: the Histogram button's glyph is accent-coloured while
    /// the histogram is on, and its tooltip names the next action.
    private func applyHistogramLook(_ item: NSToolbarItem, button: ToolbarToggleButton, on: Bool) {
        let tint: NSColor? = on ? ShrikeAccent.mark : nil
        if button.contentTintColor != tint { button.contentTintColor = tint }
        let key = Self.keyText(for: .toggleHistogram) ?? ""
        let tip = "\(on ? "Hide" : "Show") Histogram  ·  \(key)"
        if item.toolTip != tip {
            item.toolTip = tip
            button.toolTip = tip
        }
    }

    /// Current rating from the Rate menu states (0 = unrated).
    private func currentRating(_ host: any ViewerToolbarHost) -> Int {
        Self.ratingCommands.firstIndex { host.menuState(for: $0) == .on } ?? 0
    }

    private func applyRating(to item: NSToolbarItem, host: any ViewerToolbarHost) {
        let stars = currentRating(host)
        let keys = Self.ratingKeyText(ShortcutTable.livePreset)
        let tip = stars > 0 ? "Rating: \(stars) Star\(stars == 1 ? "" : "s")  ·  \(keys)" : "Rating  ·  \(keys)"
        if item.toolTip != tip {
            item.toolTip = tip
            item.view?.toolTip = tip
        }
        if shownRating != stars {
            shownRating = stars
            let image = symbol(stars > 0 ? "star.fill" : "star", "Rating")
            let glyph = stars > 0 ? image.withSymbolConfiguration(.init(paletteColors: [Badges.ratingColor])) ?? image : image
            ratingGlyph = glyph
            if let button = item.view as? NSPopUpButton {
                button.menu?.items.first?.image = glyph
                button.synchronizeTitleAndSelectedItem()
            } else {
                item.image = glyph
            }
            item.menuFormRepresentation?.image = glyph
            item.view?.setAccessibilityValue(Self.ratingValue(stars))
        }
    }

    /// VoiceOver value of the Rating item: "3 stars", "1 star", "No rating".
    static func ratingValue(_ stars: Int) -> String {
        stars > 0 ? "\(stars) star\(stars == 1 ? "" : "s")" : "No rating"
    }

    /// The Rating pull-down's row 0: the glyph its button shows.
    private func ratingGlyphRow() -> NSMenuItem {
        let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        row.image = ratingGlyph ?? symbol("star", "Rating")
        return row
    }

    /// "0–5" (Mac) or "⌃0–⌃5" (FastStone), from the shortcut table.
    static func ratingKeyText(_ preset: ShortcutPreset) -> String {
        let first = ShortcutTable.displayString(for: .rate0, context: .viewer, preset: preset)
        let last = ShortcutTable.displayString(for: .rate5, context: .viewer, preset: preset)
        return "\(first)–\(last)"
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let host else { return }
        menu.removeAllItems()
        if menu === zoomMenu || menu === zoomOverflowMenu {
            if menu === zoomMenu { menu.addItem(zoomGlyphRow()) }
            let current = NSMenuItem(title: host.toolbarZoomLine, action: nil, keyEquivalent: "")
            current.isEnabled = false
            menu.addItem(current)
            for row in Self.zoomRows {
                guard let command = row else { menu.addItem(.separator()); continue }
                let title = command == .toggleHistogram
                    ? (host.toolbarToggleIsOn(.toggleHistogram) ? "Hide Histogram" : "Show Histogram")
                    : command.title
                menu.addItem(commandItem(command, title: title, host: host, showKey: true))
            }
        } else if menu === ratingMenu || menu === ratingOverflowMenu {
            if menu === ratingMenu { menu.addItem(ratingGlyphRow()) }
            let stars = currentRating(host)
            for (n, command) in Self.ratingCommands.enumerated() {
                let title = n == 0 ? "None" : String(repeating: "★", count: n)
                let item = commandItem(command, title: title, host: host, showKey: false)
                if n > 0 {
                    item.attributedTitle = NSAttributedString(string: title, attributes: [
                        .foregroundColor: Badges.ratingColor, .font: NSFont.menuFont(ofSize: 0),
                    ])
                }
                item.state = n == stars ? .on : .off
                menu.addItem(item)
            }
        }
    }

    /// A » menu row that sends `command`, with the item's glyph
    /// (every row has an icon).
    func commandRow(_ command: ShrikeCommand, title: String, symbol name: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = command.rawValue
        row.image = symbol(name, title)
        return row
    }

    /// A » menu row for a two-button group: the group's glyph and a
    /// submenu with one row per button.
    private func submenuRow(_ title: String, symbol name: String,
                            rows: [(ShrikeCommand, String, String)]) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.image = symbol(name, title)
        let menu = NSMenu(title: title)
        for (command, rowTitle, rowSymbol) in rows {
            menu.addItem(commandRow(command, title: rowTitle, symbol: rowSymbol))
        }
        row.submenu = menu
        return row
    }

    /// The » menu (and its submenus) ask here when they open: enabled by
    /// the menu rule, and a check mark on a toggle that is on. (AppKit
    /// may show a copy of the item's menu form, so its state is set here
    /// as well as in `validate()`.)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(menuCommand(_:)), let host,
              let raw = menuItem.representedObject as? String,
              let command = ShrikeCommand(rawValue: raw) else { return true }
        if Self.toggleCommands.values.contains(command) {
            menuItem.state = host.toolbarToggleIsOn(command) ? .on : .off
        }
        return host.canPerform(command)
    }

    /// The Zoom pull-down's row 0: the glyph its button shows.
    private func zoomGlyphRow() -> NSMenuItem {
        let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        row.image = symbol("plus.magnifyingglass", "Zoom")
        return row
    }

    /// A menu row that sends `command`. Its key is shown as text only:
    /// `keyEquivalent` stays "" so the row never fires a key.
    private func commandItem(_ command: ShrikeCommand, title: String, host: any ViewerToolbarHost, showKey: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        item.isEnabled = host.canPerform(command)
        if showKey, let key = Self.keyText(for: command) {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
            item.attributedTitle = NSAttributedString(string: "\(title)\t\(key)", attributes: [
                .paragraphStyle: style, .font: NSFont.menuFont(ofSize: 0),
            ])
        }
        return item
    }

    /// "⌘0" from a resolver tooltip "Zoom to Fit  ·  ⌘0".
    static func keyText(for command: ShrikeCommand) -> String? {
        let tip = ShortcutTable.tooltip(for: command, context: .viewer)
        guard let range = tip.range(of: "  ·  ") else { return nil }
        return String(tip[range.upperBound...])
    }

    // MARK: Share

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        host?.toolbarShareURLs ?? []
    }
}

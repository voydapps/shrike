//
//  BrowserToolbarItems.swift
//  ShrikeUI
//
//  Custom `NSToolbarItem` subclasses and helper views for the browser toolbar:
//  view-mode segmented control, sort popup, filter popover trigger, and the
//  search field.
//
//  The window controller owns the actual `NSToolbar`; this file just hosts
//  the view classes so the controller's declaration stays readable.
//

import AppKit
import Foundation
import ShrikeIO

// MARK: - Toolbar item identifiers

public enum BrowserToolbarID {
    public static let backForward   = NSToolbarItem.Identifier("shrike.browser.backForward")
    public static let viewMode      = NSToolbarItem.Identifier("shrike.browser.viewMode")
    public static let sort          = NSToolbarItem.Identifier("shrike.browser.sort")
    public static let filter        = NSToolbarItem.Identifier("shrike.browser.filter")
    public static let search        = NSToolbarItem.Identifier("shrike.browser.search")
    public static let inspector     = NSToolbarItem.Identifier("shrike.browser.inspector")
    public static let openInViewer  = NSToolbarItem.Identifier("shrike.browser.openInViewer")
}

// MARK: - Toolbar layout

@MainActor
public enum BrowserToolbarLayout {

    public static let toolbarIdentifier = "shrike.browser.toolbar"

    /// Items in order, left to right.
    public static let defaultItems: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        .sidebarTrackingSeparator,
        BrowserToolbarID.backForward,
        .flexibleSpace,
        BrowserToolbarID.viewMode,
        BrowserToolbarID.sort,
        BrowserToolbarID.filter,
        BrowserToolbarID.search,
        .inspectorTrackingSeparator,
        BrowserToolbarID.inspector,
    ]

    /// Grid, Filmstrip, List.
    public static let viewModeSymbols = ["square.grid.2x2", "rectangle.bottomthird.inset.filled", "list.bullet"]

    /// View ▸ Sort By keys, in menu order.
    public static let sortCommands: [ShrikeCommand] = [
        .sortByName, .sortByDateCaptured, .sortByDateModified, .sortBySize,
        .sortByRating, .sortByKind, .sortByDimensions,
    ]

    /// AppKit's autosave key for the toolbar's items.
    public static var configurationKey: String { "NSToolbar Configuration \(toolbarIdentifier)" }
    /// Layout version already applied (one-time reset guard).
    public static let layoutVersionKey = "shrike.browser.toolbarLayoutVersion"
    public static let layoutVersion = 2

    /// Drops a toolbar layout saved by an older version once, so the new
    /// default items show. Later user changes are kept. Returns true when
    /// it reset the layout.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults) -> Bool {
        guard defaults.integer(forKey: layoutVersionKey) < layoutVersion else { return false }
        defaults.removeObject(forKey: configurationKey)
        defaults.set(layoutVersion, forKey: layoutVersionKey)
        return true
    }
}

extension BrowserSortKey {
    public var displayName: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .dateCaptured: return "Date Captured"
        case .size:         return "Size"
        case .rating:       return "Rating"
        case .kind:         return "Kind"
        case .dimensions:   return "Dimensions"
        }
    }
}

// MARK: - Filter popover

/// Rating popup, "Flagged only", Kind boxes and Clear. Changes apply at
/// once; there is no Apply button.
@MainActor
public final class BrowserFilterPopover: NSViewController {

    static let width: CGFloat = 280
    static let padding: CGFloat = 16
    static let rowGap: CGFloat = 12

    public var onChange: ((BrowserFilter) -> Void)?
    public var filter: BrowserFilter {
        didSet { refresh() }
    }

    let ratingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let flagPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var kindBoxes: [BrowserFilterKind: NSButton] = [:]
    let clearButton = NSButton(title: "Clear Filters", target: nil, action: nil)
    /// "Tags": a pull-down that closes on each pick (spec 21b §3). Items: the tags
    /// found in the folder, colour tags first.
    let tagPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The tags of the folder and whether they are still being read. The window
    /// controller feeds these; the popover never reads files itself.
    public private(set) var tagOptions: [FinderTag] = []
    public private(set) var isReadingTags = false

    public func setTagSource(_ options: [FinderTag], reading: Bool) {
        tagOptions = options
        isReadingTags = reading
        refreshTagPopup()
    }

    public init(filter: BrowserFilter) {
        self.filter = filter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return l
        }
        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.orientation = .horizontal
            r.spacing = 8
            r.alignment = .firstBaseline
            return r
        }

        for choice in BrowserRatingChoice.menuOrder {
            ratingPopup.addItem(withTitle: choice.title)
        }
        ratingPopup.target = self
        ratingPopup.action = #selector(ratingChanged(_:))
        ratingPopup.setAccessibilityLabel("Rating")

        for choice in BrowserFlagChoice.allCases { flagPopup.addItem(withTitle: choice.title) }
        flagPopup.target = self
        flagPopup.action = #selector(flagChanged(_:))
        flagPopup.setAccessibilityLabel("Flag")

        tagPopup.target = self
        tagPopup.action = #selector(tagPicked(_:))
        tagPopup.setAccessibilityLabel("Tags")

        var kindRows: [NSStackView] = []
        let kinds = BrowserFilterKind.allCases
        for (i, kind) in kinds.enumerated() {
            let box = NSButton(checkboxWithTitle: kind.title, target: self, action: #selector(kindChanged(_:)))
            box.tag = i
            kindBoxes[kind] = box
        }
        let firstRow = row([label("Kind")] + kinds.prefix(3).compactMap { kindBoxes[$0] })
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let secondRow = row([spacer] + kinds.dropFirst(3).compactMap { kindBoxes[$0] })
        kindRows = [firstRow, secondRow]
        let kindStack = NSStackView(views: kindRows)
        kindStack.orientation = .vertical
        kindStack.alignment = .leading
        kindStack.spacing = 6

        clearButton.target = self
        clearButton.action = #selector(clearTapped(_:))
        clearButton.controlSize = .regular
        let clearRow = NSStackView(views: [NSView(), clearButton])
        clearRow.orientation = .horizontal
        clearRow.distribution = .fill
        clearRow.arrangedSubviews[0].setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [
            row([label("Rating"), ratingPopup]), row([label("Flag"), flagPopup]), kindStack,
            row([label("Tags"), tagPopup]), clearRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowGap
        let pad = Self.padding
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false
        clearRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * pad).isActive = true
        ratingPopup.widthAnchor.constraint(equalToConstant: Self.width - 2 * pad - 44 - 8).isActive = true
        flagPopup.widthAnchor.constraint(equalTo: ratingPopup.widthAnchor).isActive = true
        tagPopup.widthAnchor.constraint(equalTo: ratingPopup.widthAnchor).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: Self.width, height: root.fittingSize.height)
        refresh()
    }

    private func spacerView() -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return v
    }

    private func refresh() {
        guard isViewLoaded else { return }
        ratingPopup.selectItem(at: BrowserRatingChoice.menuOrder.firstIndex(of: filter.ratingChoice) ?? 0)
        flagPopup.selectItem(at: BrowserFlagChoice.allCases.firstIndex(of: filter.flagChoice) ?? 0)
        for (kind, box) in kindBoxes {
            box.state = filter.excludedKinds.contains(kind) ? .off : .on
        }
        clearButton.isEnabled = !filter.popoverPartIsEmpty
        refreshTagPopup()
    }

    /// Finder order for colour tags, then the other tags A–Z.
    static func orderedTags(_ tags: [FinderTag]) -> [FinderTag] {
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0.name.lowercased()).inserted }
        let coloured = FinderTagColor.finderMenuOrder.flatMap { color in
            unique.filter { $0.color == color }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let rest = unique.filter { !FinderTagColor.finderMenuOrder.contains($0.color) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return coloured + rest
    }

    /// The title of the closed control: Any Tag · the tag · "2 Tags".
    var tagTitle: String {
        if isReadingTags && filter.tags.isEmpty { return "Reading Tags…" }
        switch filter.tags.count {
        case 0: return tagOptions.isEmpty ? "No Tags in This Folder" : "Any Tag"
        case 1: return filter.tags.first ?? ""
        default: return "\(filter.tags.count) Tags"
        }
    }

    /// Rebuilds the menu. Item 0 is the pull-down's title (never listed).
    func refreshTagPopup() {
        guard isViewLoaded else { return }
        let menu = tagPopup.menu ?? NSMenu()
        menu.removeAllItems()
        menu.addItem(withTitle: tagTitle, action: nil, keyEquivalent: "")
        let usable = !isReadingTags || !filter.tags.isEmpty
        tagPopup.isEnabled = usable && (!tagOptions.isEmpty || !filter.tags.isEmpty)
        if tagPopup.isEnabled {
            let any = menu.addItem(withTitle: "Any Tag", action: #selector(tagPicked(_:)), keyEquivalent: "")
            any.target = self
            any.state = filter.tags.isEmpty ? .on : .off
            menu.addItem(.separator())
            // A chosen tag the folder no longer has stays listed, so it can be unticked.
            var options = Self.orderedTags(tagOptions)
            for name in filter.tags.sorted() where !options.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                options.append(FinderTag(name: name))
            }
            for tag in options {
                let item = menu.addItem(withTitle: tag.name, action: #selector(tagPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tag.name
                item.state = filter.tags.contains(tag.name) ? .on : .off
                if let dot = Self.dotImage(for: tag.color) { item.image = dot }
            }
        }
        tagPopup.menu = menu
        tagPopup.setAccessibilityValue(tagTitle)
    }

    private static func dotImage(for color: FinderTagColor) -> NSImage? {
        guard let fill = color.nsColor else { return nil }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    @objc func tagPicked(_ sender: Any?) {
        let item: NSMenuItem?
        if let popup = sender as? NSPopUpButton { item = popup.selectedItem } else { item = sender as? NSMenuItem }
        guard let item, item !== tagPopup.menu?.items.first else { return }
        if let name = item.representedObject as? String {
            if filter.tags.contains(name) { filter.tags.remove(name) } else { filter.tags.insert(name) }
        } else {
            filter.tags = []   // "Any Tag"
        }
        changed()
    }

    private func changed() {
        refresh()
        onChange?(filter)
    }

    @objc func ratingChanged(_ sender: NSPopUpButton) {
        let order = BrowserRatingChoice.menuOrder
        guard order.indices.contains(sender.indexOfSelectedItem) else { return }
        filter.ratingChoice = order[sender.indexOfSelectedItem]
        changed()
    }

    @objc func flagChanged(_ sender: NSPopUpButton) {
        let all = BrowserFlagChoice.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        filter.flagChoice = all[sender.indexOfSelectedItem]
        changed()
    }

    @objc func kindChanged(_ sender: NSButton) {
        let kinds = BrowserFilterKind.allCases
        guard kinds.indices.contains(sender.tag) else { return }
        if sender.state == .on {
            filter.excludedKinds.remove(kinds[sender.tag])
        } else {
            filter.excludedKinds.insert(kinds[sender.tag])
        }
        changed()
    }

    @objc func clearTapped(_ sender: Any?) {
        let search = filter.searchTerm
        filter = .none
        filter.searchTerm = search
        changed()
    }
}

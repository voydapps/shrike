//
//  BrowserContentViewController.swift
//  ShrikeUI
//
//  Center pane of the browser window. Switches between three modes —
//  grid, filmstrip, and list — while reusing the same underlying
//  `[BrowserItem]` model so selection + sort + filter are mode-agnostic.
//
//  * Grid   — `NSCollectionView` flow layout, square thumbnails.
//  * Filmstrip — a large preview of the selected photo on top and, below
//    it, the same collection view as ONE horizontal row of 120 pt cells in a
//    fixed-height strip (user test 2, 2026-10-10: the old layout let the
//    scroll view fill the whole height, so a horizontal flow filled columns).
//  * List   — `NSTableView` with columns.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeRendering
import ShrikeIO

@MainActor
public protocol BrowserContentDelegate: AnyObject {
    func browserContentDidSelect(_ items: [BrowserItem])
    func browserContentDidOpen(_ items: [BrowserItem], startingAt index: Int)
    func browserContentRequestsRevealInFinder(_ items: [BrowserItem])
    func browserContentRequestsTrash(_ items: [BrowserItem])
    func browserContentRequestsRate(_ items: [BrowserItem], to rating: Int)
    func browserContentRequestsFlag(_ items: [BrowserItem], flag: Bool)
    func browserContentDidChangeMode(_ mode: BrowserViewMode)
    /// The RAW chip on a cell was clicked (that photo is selected).
    func browserContentRequestsRAWSwitch()
}

extension BrowserContentDelegate {
    public func browserContentRequestsRAWSwitch() {}
}

@MainActor
public final class BrowserContentViewController: NSViewController {

    // MARK: - Public API

    public weak var delegate: (any BrowserContentDelegate)?
    /// The Browser key map. Returns true when it consumed
    /// the event; the grid and list call `super` otherwise.
    public var keyHandler: ((NSEvent) -> Bool)?
    public let services: ShrikeServices

    public private(set) var mode: BrowserViewMode = .grid
    public private(set) var allItems: [BrowserItem] = []
    public private(set) var visibleItems: [BrowserItem] = []

    /// The chosen sort; saved to Prefs. Keys that need a
    /// file read keep the grid's order until every value is in.
    public var sort: BrowserSort = .saved {
        didSet {
            guard sort != oldValue else { return }
            sort.save()
            syncTableSortIndicator()
            sortDidChange()
        }
    }

    /// True while the list's sort descriptors are set from `sort`.
    private var isSyncingSortDescriptors = false

    /// The list column key for a sort key; nil for keys with no column.
    static func tableColumnKey(for key: BrowserSortKey) -> String? {
        switch key {
        case .name: return "name"
        case .dateModified: return "date"
        case .size: return "size"
        case .rating: return "rating"
        case .dimensions: return "dim"
        case .dateCaptured, .kind: return nil
        }
    }

    /// The sorted column shows the arrow; a sort chosen in
    /// the menu or the toolbar moves it.
    private func syncTableSortIndicator() {
        isSyncingSortDescriptors = true
        defer { isSyncingSortDescriptors = false }
        let key = Self.tableColumnKey(for: sort.key)
        let ascending = sort.direction == .ascending
        tableView.sortDescriptors = key.map { [NSSortDescriptor(key: $0, ascending: ascending)] } ?? []
        var highlighted: NSTableColumn?
        for column in tableView.tableColumns {
            if let key, column.sortDescriptorPrototype?.key == key {
                highlighted = column
                tableView.setIndicatorImage(
                    NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                    in: column)
            } else {
                tableView.setIndicatorImage(nil, in: column)
            }
        }
        tableView.highlightedTableColumn = highlighted
    }

    func refreshChromePreferences() {
        tableView.rowHeight = ChromeTypography.targetHeight
        if mode == .grid, let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: thumbnailPixelSize, height: thumbnailPixelSize + (Prefs.largerChrome ? 48 : 40))
            layout.invalidateLayout()
        }
        filterStrip.show(filter)
    }

    /// Test seam: the list view.
    var tableViewForTesting: NSTableView { tableView }
    /// Which primaries still hold a kept size (list column) or sort value.
    func keepsListDimensionsForTesting(_ url: URL) -> Bool { listDimensions[url] != nil }
    func keepsSortValueForTesting(_ url: URL) -> Bool { readValues[url] != nil }
    /// Test seam: the grid / filmstrip view.
    var collectionViewForTesting: BrowserCollectionView { collectionView }
    /// Test seam: sees what `cancelPrefetchingForItemsAt` withdraws.
    var cancelPrefetchObserverForTesting: (([any ImageSource], Int) -> Void)?
    var gridScrollViewForTesting: NSScrollView { gridScrollView }
    /// The view that takes the keys in this mode: the grid or the list
    /// (Esc in the search field hands focus back here).
    var focusView: NSView { mode == .list ? tableView : collectionView }
    /// List ▸ Dimensions for files whose listing has no size (JPEG, PNG):
    /// the header cache first, then a header read off the main thread.
    /// Keyed by file, with the modification date read at.
    private var listDimensions: [URL: (modified: Date, width: Int?, height: Int?)] = [:]
    private var listDimensionsTask: Task<Void, Never>?
    /// Files that changed on disk since the listing: their listing size may be old.
    private var listingSizeDistrusted: Set<URL> = []
    /// Header reads per batch (each batch updates the rows it filled).
    static let listDimensionsBatch = 64
    /// The sort the grid shows now (lags `sort` while values are read).
    private(set) lazy var appliedSort: BrowserSort = sort
    /// Values read for `readValuesKey`, by primary URL.
    private var readValues: [URL: SortValue] = [:]
    private var readValuesKey: BrowserSortKey?
    private var sortReadTask: Task<Void, Never>?
    /// "Sorting by Date Captured… 1,500 of 5,000" while values are read;
    /// nil when done or cancelled.
    var onSortProgress: ((String?) -> Void)?
    public var filter: BrowserFilter = .none {
        didSet {
            filterStrip.show(filter)
            applyFilterKeepingSelection()
        }
    }
    public var thumbnailPixelSize: Int = Prefs.thumbnailSizePt {
        didSet {
            applyThumbnailSize()
        }
    }

    /// Pixels to ask the thumbnail cache for: the cell's size in points at
    /// the window's screen scale, so a Retina grid is sharp. In filmstrip
    /// mode the cells are a fixed 120 pt.
    public var cellRequestPixelSize: Int {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return ThumbnailSizing.requestPixels(points: mode == .filmstrip ? 120 : thumbnailPixelSize, scale: scale)
    }

    // MARK: - Views

    /// Grid background: `surface.base`, so the `surface.sunken` cards
    /// read as wells. Follows Light/Dark live.
    private let containerView = BrowserContentContainerView(fillColor: ShrikeTokens.surfaceBase)

    /// This window's id on the private drag type: a drop
    /// that carries it back onto this grid is refused (no reordering).
    let dragSourceID = UUID().uuidString
    /// Files dropped on the content area; the Browser navigates.
    var onDropFiles: (([URL]) -> Void)?

    /// Test seam: the grid background colour.
    var gridBackgroundForTesting: NSColor { containerView.fillColor }

    private let gridScrollView = NSScrollView()
    /// Filmstrip mode: the big picture above the strip.
    private let filmstripPreview = FilmstripPreviewView()
    private var filmstripPreviewTask: Task<Void, Never>?
    /// The file the preview shows (or is loading).
    private(set) var filmstripPreviewURL: URL?
    /// A strip cell: the 120 pt thumbnail plus the room the selected cell's
    /// name capsule needs under it (4 pt gap + 18 pt capsule). Without it
    /// the name hung below the cell and the scroller cut it off.
    static let filmstripItemSize = NSSize(width: 120, height: 146)
    /// Existing outer-height floor, retained for overlay-scroller appearance.
    /// Legacy scrollers may need more space, derived from their native metrics.
    static let filmstripStripHeight: CGFloat = 8 + filmstripItemSize.height + 8 + 16
    /// The preview is decoded at most this big (the thumbnail cache).
    static let filmstripPreviewPixels = 1536
    private let collectionView = BrowserCollectionView()
    private let listScrollView = NSScrollView()
    private let tableView = BrowserTableView()
    private let emptyStateView = BrowserEmptyState()
    let filterStrip = BrowserFilterStrip(frame: .zero)
    var onFilterSummaryChange: ((BrowserFilter) -> Void)?
    var isHydratingMarks = false { didSet { updateEmptyState() } }

    // MARK: - Init

    public init(services: ShrikeServices, initialMode: BrowserViewMode = .grid) {
        self.services = services
        self.mode = initialMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Load

    public override func loadView() {
        view = containerView
        view.translatesAutoresizingMaskIntoConstraints = false
        configureCollectionView()
        configureTableView()
        configureEmptyState()
        view.addSubview(filterStrip)
        filterStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([filterStrip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), filterStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor), filterStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        filterStrip.onChange = { [weak self] value in self?.filter = value; self?.onFilterSummaryChange?(value) }
        layoutForMode()
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.itemSize = NSSize(width: thumbnailPixelSize, height: thumbnailPixelSize + (Prefs.largerChrome ? 48 : 40))
        collectionView.collectionViewLayout = layout

        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(ThumbnailItem.self,
                                forItemWithIdentifier: ThumbnailItem.reuseIdentifier)
        collectionView.setAccessibilityLabel("Thumbnail grid")
        collectionView.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        collectionView.onUserMouseDown = { [weak self] in self?.firstOnOpenPending = false }
        collectionView.revealLead = { [weak self] ip in
            guard let self else { return }
            // Filmstrip centres the moving end; the grid keeps it visible.
            if self.mode == .filmstrip { self.scrollToCenter(ip, animated: true) }
            else if let frame = self.collectionView.layoutAttributesForItem(at: ip)?.frame {
                self.collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -8))
            }
        }
        collectionView.onDoubleClick = { [weak self] indexPath in self?.openItem(at: indexPath.item) }

        let clip = NSClipView()
        clip.documentView = collectionView
        gridScrollView.contentView = clip
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.drawsBackground = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Context menu for grid cells.
        collectionView.menu = makeCollectionContextMenu()

        // Drag out copies outside Shrike, copies or moves
        // inside (a sidebar folder).
        collectionView.setDraggingSourceOperationMask(BrowserDropRules.outsideMask, forLocal: false)
        collectionView.setDraggingSourceOperationMask(BrowserDropRules.insideMask, forLocal: true)

        // Drops on the grid, the list or the empty area.
        containerView.dropValidator = { [weak self] pasteboard in
            guard let self else { return false }
            return BrowserDropRules.acceptsContentDrop(pasteboard, ownSource: self.dragSourceID)
        }
        containerView.onDrop = { [weak self] pasteboard in
            guard let self, let onDrop = self.onDropFiles else { return false }
            let urls = PhotoPasteboard.fileURLs(on: pasteboard)
            guard !urls.isEmpty else { return false }
            onDrop(urls)
            return true
        }
    }

    /// Test seams: the drop area and its border.
    var dropViewForTesting: BrowserContentContainerView { containerView }

    private func configureTableView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = ChromeTypography.targetHeight
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        tableView.style = .inset
        // The columns share the list's width, so Flag and
        // Tags are on screen (they sat past the right edge, with no
        // scroller). Thumbnail and Flag keep their width; the others
        // shrink and grow together, down to their minimum. Below that a
        // horizontal scroller appears.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("col.thumb", "",            48,  48),
            ("col.name",  "Name",        260, 110),
            ("col.date",  "Modified",    150, 100),
            ("col.dim",   "Dimensions",  110, 75),
            ("col.size",  "Size",         90, 55),
            ("col.rating","Rating",       Self.ratingColumnWidth, 44),
            ("col.flag",  "Flag",         36, 36),
            ("col.tags",  "Tags",         60, 36),
        ]
        for (id, title, width, minWidth) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = minWidth
            if minWidth == width {
                col.maxWidth = width
                col.resizingMask = []
            } else if id == "col.rating" {
                // Compact: keeps its width; Name and Tags share the rest.
                col.resizingMask = [.userResizingMask]
            } else {
                col.resizingMask = [.autoresizingMask, .userResizingMask]
            }
            col.headerCell = ListHeaderCell(textCell: title)
            switch id {
            case "col.name":   col.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
            case "col.date":   col.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
            case "col.dim":    col.sortDescriptorPrototype = NSSortDescriptor(key: "dim",  ascending: false)
            case "col.size":   col.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
            case "col.rating": col.sortDescriptorPrototype = NSSortDescriptor(key: "rating", ascending: false)
            default: break
            }
            tableView.addTableColumn(col)
        }
        applyHiddenListColumns()
        installHeaderMenu()
        syncTableSortIndicator()
        tableView.setAccessibilityLabel("Image list")

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.hasHorizontalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.drawsBackground = false
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView.menu = makeTableContextMenu()
        tableView.setDraggingSourceOperationMask(BrowserDropRules.outsideMask, forLocal: false)
        tableView.setDraggingSourceOperationMask(BrowserDropRules.insideMask, forLocal: true)
    }

    // MARK: - List columns (spec 27 P3-14)

    /// Rating shows "★3" or nothing, so it is narrow; Flag is a single glyph.
    static let ratingColumnWidth: CGFloat = 56
    /// The columns the header menu can hide: Rating, Flag, Tags, Dimensions.
    static let hideableListColumns: [(id: String, title: String)] = [
        ("col.rating", "Rating"), ("col.flag", "Flag"), ("col.tags", "Tags"), ("col.dim", "Dimensions"),
    ]

    /// Hides the columns the user hid before (restored on every new list).
    private func applyHiddenListColumns() {
        let hidden = Set(Prefs.browserListHiddenColumns)
        for column in tableView.tableColumns {
            column.isHidden = hidden.contains(column.identifier.rawValue)
        }
    }

    private func installHeaderMenu() {
        let menu = NSMenu(title: "Columns")
        menu.autoenablesItems = false
        menu.delegate = self
        for entry in Self.hideableListColumns {
            let item = NSMenuItem(title: entry.title, action: #selector(toggleListColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
        tableView.headerView?.menu = menu
    }

    /// Header menu: a tick on the shown columns, read fresh each time it opens.
    fileprivate func refreshHeaderMenuStates(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String,
                  let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { continue }
            item.state = column.isHidden ? .off : .on
        }
    }

    @objc func toggleListColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        column.isHidden.toggle()
        var hidden = Set(Prefs.browserListHiddenColumns)
        if column.isHidden { hidden.insert(id) } else { hidden.remove(id) }
        Prefs.browserListHiddenColumns = tableView.tableColumns.map(\.identifier.rawValue).filter(hidden.contains)
    }

    /// Test seams.
    var headerMenuForTesting: NSMenu? { tableView.headerView?.menu }
    func refreshHeaderMenuForTesting() { if let menu = tableView.headerView?.menu { refreshHeaderMenuStates(menu) } }

    private func configureEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
    }

    // MARK: - Layout

    /// The list's columns start at their full widths, wider than most
    /// windows; once the list has its width they are fitted to it (the
    /// uniform autoresizing then keeps them fitted as the window changes).
    override public func viewWillLayout() {
        refreshFilmstripHeight()
        super.viewWillLayout()
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        fitListColumns()
        keepFilmstripSelectionCentred()
    }

    /// The strip's width when the selection was last centred.
    private var filmstripCentredWidth: CGFloat = 0

    /// The strip got another width (the inspector opened or closed, the
    /// window changed, the view switched to the filmstrip): the selected
    /// cell is centred again, so it never ends up beyond the new edge.
    private func keepFilmstripSelectionCentred() {
        guard mode == .filmstrip else { filmstripCentredWidth = 0; return }
        let width = gridScrollView.contentView.bounds.width
        guard width > 0, abs(width - filmstripCentredWidth) > 0.5 else { return }
        guard !isCarryingSelection else { return }
        filmstripCentredWidth = width
        // A select-all (or any several items without a known moving end)
        // has no item to centre: the strip stays where it is.
        let selected = collectionView.selectionIndexPaths
        if selected.count > 1 && !collectionView.hasKeyMovingEnd { return }
        if let ip = collectionView.keyRange?.lead ?? selected.min() {
            scrollToCenter(ip, animated: false)
        }
    }

    /// The list's text font (every text cell).
    static let listFont = ChromeTypography.font(13)
    private var listColumnFitsApplied = false

    /// Dimensions and Modified were cut in the middle
    /// ("5184…456", "27 Sep…t 08:20") at the default window size, because
    /// the uniform autoresizing shrank every column by the same amount.
    /// They now start at the width their longest text needs (measured
    /// with the list font, in the user's locale) and keep it when the
    /// window changes; Name, Size, Rating and Tags share the rest. The
    /// user can still drag them wider. Measured once, when the list first
    /// shows (never on the grid's first paint).
    private func applyListColumnFits() {
        guard !listColumnFitsApplied else { return }
        listColumnFitsApplied = true
        let gap = tableView.intercellSpacing.width
        let fits: [String: CGFloat] = [
            "col.date": Self.cellFitWidth(Self.longestDateSamples(), gap: gap),
            "col.dim": Self.cellFitWidth(Self.dimensionSamples, gap: gap),
        ]
        for column in tableView.tableColumns {
            guard let fit = fits[column.identifier.rawValue] else { continue }
            column.minWidth = fit
            column.width = fit
            column.resizingMask = [.userResizingMask]
        }
    }

    /// The column width that shows the widest of `samples` whole in a list
    /// cell: the label's own size, the cell's 4 pt margins, the gap
    /// between columns, and 2 pt to spare.
    static func cellFitWidth(_ samples: [String], gap: CGFloat) -> CGFloat {
        let probe = NSTextField(labelWithString: "")
        probe.font = listFont
        var widest: CGFloat = 0
        for sample in samples {
            probe.stringValue = sample
            widest = max(widest, probe.intrinsicContentSize.width)
        }
        return ceil(widest + 8 + gap + 2)
    }

    /// "8888 × 8888": the widest size a camera photo shows (four places
    /// per side; 8 is the widest numeral).
    static let dimensionSamples = ["8888 × 8888", "5184 × 3456"]

    /// The Modified text for a late day of every month at 22:58 (the
    /// longest hour in 12- and 24-hour clocks), in the user's locale.
    static func longestDateSamples() -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dateFormatter.timeZone ?? .current
        return (1...12).compactMap { month in
            calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: 22, minute: 58))
                .map { dateFormatter.string(from: $0) }
        }
    }

    private func fitListColumns() {
        let clip = listScrollView.contentView
        guard mode == .list, clip.bounds.width > 0, tableView.frame.width > clip.bounds.width + 0.5 else { return }
        tableView.sizeToFit()
    }

    /// The filmstrip strip's fixed height. A height-only constraint lives on
    /// the scroll view itself, so it survives `removeFromSuperview`; left
    /// active, the grid kept the strip's 178 pt and the window shrank to
    /// fit it (580 pt tall in ⌘2, 202 pt after ⌘1).
    private func filmstripFrameHeight() -> CGFloat {
        let insets = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.sectionInset
            ?? NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let contentHeight = Self.filmstripItemSize.height + insets.top + insets.bottom
        let scrollerClass: AnyClass = gridScrollView.horizontalScroller.map { type(of: $0) } ?? NSScroller.self
        func frameHeight(_ style: NSScroller.Style) -> CGFloat {
            NSScrollView.frameSize(forContentSize: NSSize(width: 1, height: contentHeight),
                horizontalScrollerClass: scrollerClass, verticalScrollerClass: nil,
                borderType: gridScrollView.borderType,
                controlSize: gridScrollView.horizontalScroller?.controlSize ?? .regular,
                scrollerStyle: style).height
        }
        // Reserve native legacy capacity even while overlay scrollers show:
        // AppKit retiles inside a live style setter, before a later layout pass.
        return max(Self.filmstripStripHeight, ceil(frameHeight(gridScrollView.scrollerStyle)), ceil(frameHeight(.legacy)))
    }
    private func refreshFilmstripHeight() {
        guard mode == .filmstrip, let constraint = filmstripStripHeightConstraint, constraint.isActive else { return }
        let height = filmstripFrameHeight()
        if abs(constraint.constant - height) > 0.01 { constraint.constant = height }
    }

    private var filmstripStripHeightConstraint: NSLayoutConstraint?

    private func layoutForMode() {
        filmstripStripHeightConstraint?.isActive = false
        filmstripStripHeightConstraint = nil
        filmstripPreviewTask?.cancel()
        filmstripPreview.removeFromSuperview()
        gridScrollView.removeFromSuperview()
        listScrollView.removeFromSuperview()
        emptyStateView.removeFromSuperview()

        // Spec 24 §2: the hover look belongs to the filmstrip view's strip.
        collectionView.hoverEnabled = mode == .filmstrip
        let activeScroll: NSView
        switch mode {
        case .grid, .filmstrip:
            activeScroll = gridScrollView
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                switch mode {
                case .grid:
                    layout.scrollDirection = .vertical
                    layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
                    layout.itemSize = NSSize(width: thumbnailPixelSize, height: thumbnailPixelSize + (Prefs.largerChrome ? 48 : 40))
                    gridScrollView.hasHorizontalScroller = false
                    gridScrollView.hasVerticalScroller = true
                case .filmstrip:
                    layout.scrollDirection = .horizontal
                    layout.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
                    layout.itemSize = Self.filmstripItemSize
                    gridScrollView.hasHorizontalScroller = true
                    gridScrollView.hasVerticalScroller = false
                case .list:
                    break
                }
            }
        case .list:
            activeScroll = listScrollView
            applyListColumnFits()
        }

        applyWheelStep()
        view.addSubview(activeScroll)
        view.addSubview(emptyStateView)
        activeScroll.translatesAutoresizingMaskIntoConstraints = false
        if mode == .filmstrip {
            // Preview on top, one fixed-height strip below.
            filmstripPreview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(filmstripPreview, positioned: .below, relativeTo: activeScroll)
            let stripHeight = activeScroll.heightAnchor.constraint(equalToConstant: filmstripFrameHeight())
            filmstripStripHeightConstraint = stripHeight
            NSLayoutConstraint.activate([
                stripHeight,
                filmstripPreview.topAnchor.constraint(equalTo: filterStrip.bottomAnchor),
                filmstripPreview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                filmstripPreview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                filmstripPreview.bottomAnchor.constraint(equalTo: activeScroll.topAnchor),
                activeScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                activeScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                activeScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                activeScroll.topAnchor.constraint(equalTo: filterStrip.bottomAnchor),
                activeScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                activeScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                activeScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        containerView.installHighlight()
    }

    /// Grid, filmstrip and list show one selection: the switch carries the selected items, the
    /// keyboard / shift-click anchor and the keys into the new view, and
    /// scrolls the first selected item into view. Every action reads
    /// `selectedItems`, which reads the view on screen, so Compare,
    /// ratings, Q, Delete and drags act on what the user sees.
    public func setMode(_ newMode: BrowserViewMode) {
        guard newMode != mode else { return }
        let selected = selectedItems.map(\.url)
        let anchor = selectionAnchorURL
        let hadKeys = isViewLoaded && view.window != nil && view.window?.firstResponder === focusView
        isCarryingSelection = true
        mode = newMode
        layoutForMode()
        refresh()
        restoreSelection(selected, anchor: anchor)
        isCarryingSelection = false
        if hadKeys { view.window?.makeFirstResponder(focusView) }
        updateFilmstripPreview()
        // The Filmstrip shows one photo large: with none selected it would
        // be an empty box, so the first photo is selected.
        selectFirstIfFilmstripIsEmpty()
        // The same items are selected: the inspector and the status bar
        // hear it only if some item could not be shown.
        if selectedItems.map(\.url) != selected { notifySelection() }
        fillListDimensions()
        delegate?.browserContentDidChangeMode(newMode)
    }

    /// True while a view switch moves the selection (no inspector
    /// update: it stays the same).
    private var isCarryingSelection = false

    /// The anchor of the selection in the view on screen: the grid's
    /// shift-click / keyboard anchor, or the list's anchor row (the
    /// table's first selected row, as NSTableView ranges from there after
    /// a switch). Nil when the anchor is not selected.
    var selectionAnchorURL: URL? {
        switch mode {
        case .grid, .filmstrip:
            guard let anchor = collectionView.selectionAnchor,
                  collectionView.selectionIndexPaths.contains(anchor),
                  visibleItems.indices.contains(anchor.item) else { return nil }
            return visibleItems[anchor.item].url
        case .list:
            if let url = listAnchorURL,
               let row = visibleItems.firstIndex(where: { $0.url == url }),
               tableView.selectedRowIndexes.contains(row) { return url }
            guard let row = tableView.selectedRowIndexes.first, visibleItems.indices.contains(row) else { return nil }
            return visibleItems[row].url
        }
    }

    /// The grid's ⇧-arrow range as files, so it outlives a re-list.
    private var gridKeyRangeURLs: (anchor: URL, lead: URL)? {
        guard mode != .list, isViewLoaded, let range = collectionView.keyRange,
              visibleItems.indices.contains(range.anchor.item),
              visibleItems.indices.contains(range.lead.item) else { return nil }
        return (visibleItems[range.anchor.item].url, visibleItems[range.lead.item].url)
    }

    /// Set by `setItems` for the `select(urls:)` that follows a re-list.
    private var carriedKeyRange: (anchor: URL, lead: URL)?

    /// The anchor carried into the list from the grid; the list's own
    /// clicks move NSTableView's anchor, so it only counts while that
    /// row is still selected.
    private var listAnchorURL: URL?

    /// Selects `urls` in the view on screen with `anchor` as the range
    /// anchor, and scrolls the first selected item into view.
    private func restoreSelection(_ urls: [URL], anchor: URL?, scrollToFirst: Bool = true) {
        let groups = visibleItems.map(\.group)
        let indices = urls.compactMap { FolderScanner.index(of: $0, in: groups) }.sorted()
        let anchorIndex = anchor.flatMap { FolderScanner.index(of: $0, in: groups) }
            .flatMap { indices.contains($0) ? $0 : nil }
        // The new view gets its size first, so the scroll lands.
        if scrollToFirst, !indices.isEmpty, view.window != nil { view.layoutSubtreeIfNeeded() }
        switch mode {
        case .grid, .filmstrip:
            collectionView.selectionIndexPaths = Set(indices.map { IndexPath(item: $0, section: 0) })
            collectionView.restoreAnchor(anchorIndex.map { IndexPath(item: $0, section: 0) })
            if scrollToFirst, let first = indices.first {
                collectionView.scrollToItems(at: [IndexPath(item: first, section: 0)],
                                             scrollPosition: mode == .filmstrip ? .centeredHorizontally
                                                                                : .centeredVertically)
            }
        case .list:
            listAnchorURL = anchorIndex.map { visibleItems[$0].url }
            // The anchor row first: NSTableView ranges ⇧-arrows and
            // shift-clicks from the row it selected first.
            if let anchorIndex {
                tableView.selectRowIndexes(IndexSet(integer: anchorIndex), byExtendingSelection: false)
                tableView.selectRowIndexes(IndexSet(indices), byExtendingSelection: true)
            } else {
                tableView.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
            }
            if scrollToFirst, let first = indices.first { tableView.scrollRowToVisible(first) }
        }
    }

    // MARK: - Item loading

    /// Replace the model with a fresh set of items. Typically the result of
    /// a folder-switch; the caller hands us a pre-enumerated array.
    public func setItems(_ items: [BrowserItem]) {
        // A re-list puts the selection back with `select(urls:)`; the
        // ⇧-arrow range comes back with it.
        carriedKeyRange = gridKeyRangeURLs
        firstOnOpenPending = false
        allItems = BrowserPipeline.nameOrdered(items)
        cullingChangedSinceListing = []
        tagsChangedSinceListing = []
        folderGoneState = nil
        folderReadErrorState = nil
        folderLoadingState = nil
        cancelSortRead()
        recomputeVisibleItems()
        if sort.key.needsReading, !allItems.isEmpty,
           readValuesKey != sort.key || allItems.contains(where: { readValues[$0.group.primary] == nil }) {
            startSortRead()
        } else {
            appliedSort = sort
        }
    }

    // MARK: - Sort

    private func sortDidChange() {
        // The user chose another order: the open-time selection stays.
        firstOnOpenPending = false
        cancelSortRead()
        if sort.key.needsReading, !allItems.isEmpty,
           readValuesKey != sort.key || allItems.contains(where: { readValues[$0.group.primary] == nil }) {
            startSortRead()
        } else {
            appliedSort = sort
            resortKeepingSelection()
        }
    }

    /// Reads the key's values off the main thread, then re-sorts once.
    private func startSortRead() {
        let key = sort.key
        let groups = allItems.map(\.group)
        let total = groups.count
        let readerKey: SortKey = key == .dateCaptured ? .dateCaptured : .dimensions
        let reader = SortKeyReader(metadata: services.metadataStore)
        let title = key.displayName
        onSortProgress?(BrowserBottomBar.sortingText(key: title, done: 0, total: total))
        sortReadTask = Task { [weak self] in
            var values: [URL: SortValue] = [:]
            values.reserveCapacity(total)
            for await batch in await reader.values(for: groups, key: readerKey) {
                guard !Task.isCancelled else { return }
                values.merge(batch) { _, new in new }
                self?.onSortProgress?(BrowserBottomBar.sortingText(key: title, done: values.count, total: total))
            }
            guard !Task.isCancelled, let self else { return }
            self.sortReadTask = nil
            self.readValues = values
            self.readValuesKey = key
            self.appliedSort = self.sort
            self.onSortProgress?(nil)
            self.resortKeepingSelection()
        }
    }

    private func cancelSortRead() {
        guard let task = sortReadTask else { return }
        task.cancel()
        sortReadTask = nil
        onSortProgress?(nil)
    }

    /// Waits for a running value read (tests).
    func waitForSortRead() async { await sortReadTask?.value }
    var isReadingSortValuesForTesting: Bool { sortReadTask != nil }

    /// A filter keeps the selected items it still shows and
    /// drops the ones it hides, so the inspector and the status bar never
    /// describe a photo that is not on screen.
    private func applyFilterKeepingSelection() {
        let selected = selectedItems.map(\.url)
        recomputeVisibleItems()
        switch mode {
        case .grid, .filmstrip: collectionView.selectionIndexPaths = []
        case .list: tableView.deselectAll(nil)
        }
        if selected.isEmpty || !select(urls: selected) { notifySelection() }
        keepSelectionInView()
    }

    /// Spec 27 N7: after a sort or a filter the first selected item stays on
    /// screen. It scrolls (to the middle) only when it is off screen; an item
    /// already visible does not move the view.
    func keepSelectionInView() {
        switch mode {
        case .grid, .filmstrip:
            guard let first = collectionView.selectionIndexPaths.min(),
                  let frame = collectionView.layoutAttributesForItem(at: first)?.frame else { return }
            if !collectionView.visibleRect.intersects(frame) { scrollToCenter(first, animated: false) }
        case .list:
            guard let row = tableView.selectedRowIndexes.first else { return }
            if !tableView.visibleRect.intersects(tableView.rect(ofRow: row)) { tableView.scrollRowToVisible(row) }
        }
    }

    /// Re-sorts, keeps the selection and scrolls its first item into view.
    private func resortKeepingSelection() {
        let selected = selectedItems.map(\.url)
        let anchor = selectionAnchorURL
        let keyRange = gridKeyRangeURLs
        // Old indices refer to different files after filtering or sorting.
        // Restore surviving URLs only; an empty result has no action target.
        switch mode {
        case .grid, .filmstrip: collectionView.selectionIndexPaths = []
        case .list: tableView.deselectAll(nil)
        }
        recomputeVisibleItems()
        // Only the automatic first photo is selected (nobody chose
        // anything yet): after the re-sort the first photo ON SCREEN is the
        // selected one, scrolled to, as it would be had the order been
        // known at open.
        if firstOnOpenPending, let first = visibleItems.first {
            if selected != [first.url] || !selectionIsShown(first.url) {
                selectingFirst = true
                select(url: first.url)
                selectingFirst = false
            }
            return
        }
        restoreSelection(selected, anchor: anchor, scrollToFirst: false)
        if mode != .list, let keyRange {
            let groups = visibleItems.map(\.group)
            if let anchor = FolderScanner.index(of: keyRange.anchor, in: groups),
               let lead = FolderScanner.index(of: keyRange.lead, in: groups),
               collectionView.selectionIndexPaths.contains(IndexPath(item: anchor, section: 0)),
               collectionView.selectionIndexPaths.contains(IndexPath(item: lead, section: 0)) {
                collectionView.restoreAnchor(IndexPath(item: anchor, section: 0), lead: IndexPath(item: lead, section: 0))
            }
        }
        carriedKeyRange = nil
        notifySelection()
        keepSelectionInView()
    }

    /// "Folder gone": the listed folder was deleted, moved or its
    /// disk was disconnected. Cleared by the next `setItems`.
    private var folderLoadingState: URL?
    private var folderReadErrorState: (folder: URL, reason: String, retry: () -> Void)?
    private var folderGoneState: (folder: URL, action: () -> Void)?

    func showFolderGone(_ folder: URL, goToEnclosingFolder: @escaping () -> Void) {
        listDimensionsTask?.cancel()
        listDimensionsTask = nil
        allItems = []
        visibleItems = []
        folderGoneState = (folder, goToEnclosingFolder)
        refresh()
        updateEmptyState()
    }

    func showFolderLoading(_ folder: URL) {
        setItems([])
        folderLoadingState = folder
        updateEmptyState()
    }

    func showFolderReadError(_ folder: URL, reason: String, retry: @escaping () -> Void) {
        setItems([])
        folderReadErrorState = (folder, reason, retry)
        updateEmptyState()
    }

    /// Test seam: the content-area state on screen (nil when hidden).
    var emptyStateForTesting: BrowserEmptyState? { emptyStateView.isHidden ? nil : emptyStateView }

    /// The shown folder, for the empty-folder copy. The
    /// window counts the subfolders off the main thread, asks the sidebar
    /// whether it shows them, and sets it again.
    var emptyFolder: (name: String, subfolders: Int, inSidebar: Bool)? {
        didSet { updateEmptyState() }
    }

    /// The line under "No images in …".
    static func emptyFolderSubtitle(subfolders: Int, inSidebar: Bool) -> String {
        switch (subfolders, inSidebar) {
        case (0, _): return ""
        case (_, true): return "Subfolders are in the sidebar."
        case (1, false): return "This folder has 1 subfolder."
        default: return "This folder has \(subfolders) subfolders."
        }
    }

    /// "Clear Filter" in the empty result. The window owns the filter.
    var onClearFilter: (() -> Void)?
    var onChooseAnotherFolder: (() -> Void)?

    /// Update a single item's mutable fields (rating / flag / tags) in place.
    /// Keeps selection and scroll position stable.
    /// URLs whose rating / flag, or whose tags, changed since the last
    /// listing. A late hydrate never overwrites those fields with older
    /// values, but still brings the other fields of the same file (a file
    /// rated before the hydrate lands keeps its tags and edit mark).
    private var cullingChangedSinceListing: Set<URL> = []
    private var tagsChangedSinceListing: Set<URL> = []

    /// Saved values (rating, flag, tags, edit mark) read after the first
    /// paint. Updates the items in place: visible cells
    /// get their badges without reloading the thumbnail, and the
    /// selection and scroll position stay. Re-filters or re-sorts only
    /// when the filter or the sort key depends on those values.
    public func applyHydrated(_ hydrated: [BrowserItem]) {
        var byURL: [URL: BrowserItem] = [:]
        for var item in hydrated {
            // Keep the newer values written since the listing.
            if cullingChangedSinceListing.contains(item.url) || tagsChangedSinceListing.contains(item.url),
               let current = allItems.first(where: { $0.url == item.url }) {
                if cullingChangedSinceListing.contains(item.url) {
                    item.rating = current.rating
                    item.isFlagged = current.isFlagged
                }
                if tagsChangedSinceListing.contains(item.url) {
                    item.finderTags = current.finderTags
                    item.tags = current.tags
                }
            }
            byURL[item.url] = item
        }
        guard !byURL.isEmpty else { return }
        func merge(_ item: inout BrowserItem) -> Bool {
            guard let h = byURL[item.url] else { return false }
            guard item.rating != h.rating || item.isFlagged != h.isFlagged
                    || item.tags != h.tags || item.edited != h.edited else { return false }
            item.rating = h.rating
            item.isFlagged = h.isFlagged
            item.finderTags = h.finderTags
            item.tags = h.tags
            item.edited = h.edited
            return true
        }
        var anyChanged = false
        for i in allItems.indices where merge(&allItems[i]) { anyChanged = true }
        guard anyChanged else { return }
        if !filter.isEmpty || appliedSort.key == .rating {
            resortKeepingSelection()
            return
        }
        var changed: [Int] = []
        for i in visibleItems.indices where merge(&visibleItems[i]) { changed.append(i) }
        redrawMarks(at: changed)
    }

    /// Every grid / filmstrip cell made so far (on screen, prepared
    /// around it, or waiting for reuse). Weak: the collection view owns
    /// them.
    private let madeCells = NSHashTable<ThumbnailItem>.weakObjects()

    /// Redraws the marks (rating, flag, tags, edit mark) of the items at
    /// `indices` of `visibleItems` without reloading their cells, so the
    /// selection, the shift-click anchor, the first responder, the scroll
    /// position and the thumbnails stay.
    /// `reloadItems(at:)` drops the reloaded items from the selection.
    /// Grid / filmstrip: every made cell that shows one of those files
    /// gets its marks in place; cells made later read the new model.
    /// List: those rows reload; the selection is put back if the table
    /// dropped it.
    private func redrawMarks(at indices: [Int]) {
        guard !indices.isEmpty, isViewLoaded else { return }
        switch mode {
        case .grid, .filmstrip:
            var byURL: [URL: Int] = [:]
            for i in indices where visibleItems.indices.contains(i) { byURL[visibleItems[i].url] = i }
            for cell in madeCells.allObjects {
                guard let url = cell.representedURL, let i = byURL[url] else { continue }
                cell.updateMarks(visibleItems[i])
            }
        case .list:
            let rows = IndexSet(indices.filter { $0 < tableView.numberOfRows })
            guard !rows.isEmpty else { return }
            let selection = tableView.selectedRowIndexes
            tableView.reloadData(forRowIndexes: rows,
                                 columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            if tableView.selectedRowIndexes != selection {
                tableView.selectRowIndexes(selection, byExtendingSelection: false)
            }
        }
    }

    public func updateItem(_ updated: BrowserItem) {
        if let i = allItems.firstIndex(where: { $0.url == updated.url }) {
            allItems[i] = updated
        }
        if let i = visibleItems.firstIndex(where: { $0.url == updated.url }) {
            visibleItems[i] = updated
            reloadVisibleRow(index: i)
        }
    }

    /// Rating / flag values saved for some files: update those items and
    /// redraw only their cells, keeping selection.
    public func applyCulling(_ values: [URL: FileRecord]) {
        guard !values.isEmpty else { return }
        // Even an equal confirmed write supersedes a held older hydrate.
        cullingChangedSinceListing.formUnion(values.keys)
        var ratingChanged = false, flagChanged = false
        for i in allItems.indices {
            guard let record = values[allItems[i].url] else { continue }
            ratingChanged = ratingChanged || allItems[i].rating != record.rating
            flagChanged = flagChanged || allItems[i].isFlagged != record.flagged
            allItems[i].rating = record.rating
            allItems[i].isFlagged = record.flagged
        }
        guard ratingChanged || flagChanged else { return }
        if (ratingChanged && (filter.minimumRating > 0 || filter.unratedOnly || appliedSort.key == .rating))
            || (flagChanged && (filter.flaggedOnly || filter.unflaggedOnly)) {
            firstOnOpenPending = false
            resortKeepingSelection()
            return
        }
        var changed: [Int] = []
        for i in visibleItems.indices {
            guard let record = values[visibleItems[i].url] else { continue }
            visibleItems[i].rating = record.rating
            visibleItems[i].isFlagged = record.flagged
            changed.append(i)
        }
        redrawMarks(at: changed)
    }

    /// Finder tags re-read for some files: update those
    /// items and redraw only their cells, keeping selection.
    public func applyTags(_ values: [URL: [FinderTag]]) {
        guard !values.isEmpty else { return }
        tagsChangedSinceListing.formUnion(values.keys)
        var changedNames = false, changedTags = false
        for i in allItems.indices {
            guard let tags = values[allItems[i].url] else { continue }
            changedNames = changedNames || allItems[i].tags != tags.map(\.name)
            changedTags = changedTags || allItems[i].finderTags != tags
            allItems[i].finderTags = tags
            allItems[i].tags = tags.map(\.name)
        }
        guard changedNames || changedTags else { return }
        if changedNames, !filter.tags.isEmpty {
            firstOnOpenPending = false
            resortKeepingSelection()
            return
        }
        var changed: [Int] = []
        for i in visibleItems.indices {
            guard let tags = values[visibleItems[i].url] else { continue }
            visibleItems[i].finderTags = tags
            visibleItems[i].tags = tags.map(\.name)
            changed.append(i)
        }
        // In place: a tag edit keeps the selection (the inspector and the
        // popover act on it).
        redrawMarks(at: changed)
    }

    /// The view the Tags popover points at: the first selected cell or
    /// row, else the whole content.
    func anchorForSelection() -> NSView {
        switch mode {
        case .grid, .filmstrip:
            if let first = collectionView.selectionIndexPaths.min(),
               let view = collectionView.item(at: first)?.view { return view }
            return collectionView
        case .list:
            if let row = tableView.selectedRowIndexes.first,
               let view = tableView.rowView(atRow: row, makeIfNecessary: false) { return view }
            return tableView
        }
    }

    private func recomputeVisibleItems() {
        visibleItems = BrowserPipeline.filterAndSort(
            allItems, filter: filter, sort: appliedSort,
            values: readValuesKey == appliedSort.key ? readValues : nil
        )
        refresh()
        updateEmptyState()
        fillListDimensions()
    }

    // MARK: - List ▸ Dimensions

    /// "6000 × 4000" for the Dimensions column: the listing's size, else
    /// the header size found for the file at its listed date.
    func listDimensionsText(_ item: BrowserItem) -> String {
        // The freshest value first: a header read at this very date. The listing's
        // size can be old when a file changed without its date moving (a rotate
        // within the same second), so after a change it is not trusted.
        if let known = listDimensions[item.url], known.modified == item.modificationDate,
           let w = known.width, let h = known.height, w > 0, h > 0 {
            return "\(w) × \(h)"
        }
        if !listingSizeDistrusted.contains(item.url), let w = item.pixelWidth, let h = item.pixelHeight {
            return "\(w) × \(h)"
        }
        return "—"
    }

    /// In list mode, finds the sizes the listing lacks: the header cache
    /// in one database read, then the rest from the files' headers off
    /// the main thread (stored in the cache, so a later Dimensions sort
    /// reads nothing). Rows fill in as batches land. Nothing runs in the
    /// grid or filmstrip; a new call replaces a running one.
    private func fillListDimensions() {
        listDimensionsTask?.cancel()
        listDimensionsTask = nil
        guard mode == .list else { return }
        let needed = visibleItems.filter { item in
            guard item.pixelWidth == nil || item.pixelHeight == nil
                    || listingSizeDistrusted.contains(item.url) else { return false }
            return listDimensions[item.url]?.modified != item.modificationDate
        }
        guard !needed.isEmpty else { return }
        let dates = Dictionary(needed.map { ($0.url, $0.modificationDate) }, uniquingKeysWith: { a, _ in a })
        let order = needed.map(\.url)
        let metadata = services.metadataStore
        listDimensionsTask = Task { [weak self] in
            let cached = await metadata.cachedHeaders(for: dates)
            guard !Task.isCancelled, let self else { return }
            self.applyListDimensions(cached, dates: dates)
            let toRead = order.filter { cached[$0] == nil }
            var start = 0
            while start < toRead.count {
                let batch = Array(toRead[start..<min(start + Self.listDimensionsBatch, toRead.count)])
                start += batch.count
                let read = await Self.readHeaders(batch)
                guard !Task.isCancelled else { return }
                self.applyListDimensions(read, dates: dates)
                var store: [URL: (modified: Date, info: ImageHeaderInfo)] = [:]
                for (url, info) in read { if let date = dates[url] { store[url] = (date, info) } }
                await metadata.storeHeaders(store)
            }
            if !Task.isCancelled { self.listDimensionsTask = nil }
        }
    }

    /// Header reads, a few at a time, never on the main thread. A file
    /// that can't be read gets an empty entry, so it isn't tried again.
    @concurrent
    nonisolated static func readHeaders(_ urls: [URL]) async -> [URL: ImageHeaderInfo] {
        await withTaskGroup(of: (URL, ImageHeaderInfo).self) { group in
            var out: [URL: ImageHeaderInfo] = [:]
            var next = 0
            let width = 4
            while next < min(width, urls.count) {
                let url = urls[next]
                next += 1
                group.addTask { (url, ImageHeaderInfo.read(url) ?? ImageHeaderInfo()) }
            }
            for await (url, info) in group {
                out[url] = info
                if next < urls.count, !Task.isCancelled {
                    let url = urls[next]
                    next += 1
                    group.addTask { (url, ImageHeaderInfo.read(url) ?? ImageHeaderInfo()) }
                }
            }
            return out
        }
    }

    /// Keeps the found sizes and redraws the Dimensions cells on screen.
    private func applyListDimensions(_ infos: [URL: ImageHeaderInfo], dates: [URL: Date]) {
        guard !infos.isEmpty else { return }
        for (url, info) in infos {
            guard let date = dates[url] else { continue }
            listDimensions[url] = (date, info.pixelWidth, info.pixelHeight)
        }
        guard mode == .list, isViewLoaded,
              let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "col.dim" })
        else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        var changed = IndexSet()
        for row in rows.location..<(rows.location + rows.length)
        where visibleItems.indices.contains(row) && infos[visibleItems[row].url] != nil {
            changed.insert(row)
        }
        guard !changed.isEmpty else { return }
        let selection = tableView.selectedRowIndexes
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: column))
        if tableView.selectedRowIndexes != selection {
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
        }
    }

    /// These files changed on disk (a rotate, a save, an undo, an outside
    /// edit): forget every size read for them, so the next listing reads
    /// the size of the file as it is now (Dimensions column and sort).
    func forgetFileSizes(for urls: [URL]) {
        for url in urls {
            for key in [url, url.standardizedFileURL] {
                listDimensions[key] = nil
                readValues[key] = nil
                listingSizeDistrusted.insert(key)
            }
        }
    }

    /// Waits for the list's size fill (tests).
    func waitForListDimensions() async { await listDimensionsTask?.value }

    /// Whole-grid reloads (tests: a rating reloads nothing).
    private(set) var reloadCount = 0
    /// Cells configured (each one asks for its thumbnail).
    private(set) var configureCount = 0
    /// Nil in ordinary use: regression-owned observations allocate no production ledger.
    var listMaterializationStatsForTesting: BrowserListMaterializationStats?

    private func refresh() {
        reloadCount += 1
        switch mode {
        case .grid, .filmstrip:
            collectionView.reloadData()
        case .list:
            tableView.reloadData()
        }
        if mode == .filmstrip { updateFilmstripPreview() }
    }

    private func reloadVisibleRow(index: Int) {
        switch mode {
        case .grid, .filmstrip:
            collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
        case .list:
            tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                                 columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }

    private func updateEmptyState() {
        if let gone = folderGoneState {
            emptyStateView.configure(
                symbol: "questionmark.folder",
                title: "“\(gone.folder.lastPathComponent)” is no longer available.",
                subtitle: "It may have been moved, or its disk was disconnected.",
                buttonTitle: "Go to Enclosing Folder",
                action: gone.action
            )
            emptyStateView.isHidden = false
        } else if let folder = folderLoadingState {
            emptyStateView.configure(symbol: nil, title: "Opening “\(folder.lastPathComponent)”…",
                                    subtitle: "", buttonTitle: nil, action: nil)
            emptyStateView.isHidden = false
        } else if let failure = folderReadErrorState {
            emptyStateView.configure(symbol: "exclamationmark.triangle",
                title: "Couldn't open “\(failure.folder.lastPathComponent)”.",
                subtitle: failure.reason, buttonTitle: "Retry", action: failure.retry)
            emptyStateView.setSecondary(onChooseAnotherFolder)
            emptyStateView.isHidden = false
        } else if allItems.isEmpty {
            // Nothing here adds files,
            // so there is no drop hint and no button.
            let name = emptyFolder?.name ?? ""
            emptyStateView.configure(
                symbol: "photo.on.rectangle",
                title: name.isEmpty ? "No images in this folder." : "No images in “\(name)”.",
                subtitle: Self.emptyFolderSubtitle(subfolders: emptyFolder?.subfolders ?? 0,
                                                   inSidebar: emptyFolder?.inSidebar ?? false),
                buttonTitle: nil,
                action: nil
            )
            emptyStateView.isHidden = false
        } else if isHydratingMarks && filter.requiresMarkHydration && visibleItems.isEmpty {
            emptyStateView.configure(title: "Loading ratings and tags…", subtitle: "")
            emptyStateView.isHidden = false
        } else if visibleItems.isEmpty {
            let searching = !filter.searchTerm.isEmpty
            let filtering = !filter.popoverPartIsEmpty
            let actionTitle = searching ? (filtering ? "Clear Search and Filters" : "Clear Search") : "Clear Filters"
            emptyStateView.configure(symbol: nil, title: "No Matching Photos", subtitle: searching && !filtering ? "No file names match ‘\(filter.searchTerm)’." : "No photos match these search and filter settings.",
                                     buttonTitle: actionTitle,
                                     action: { [weak self] in self?.onClearFilter?() })
            emptyStateView.isHidden = false
        } else {
            emptyStateView.isHidden = true
        }
    }

    // MARK: - Selection

    public var selectedItems: [BrowserItem] {
        switch mode {
        case .grid, .filmstrip:
            return collectionView.selectionIndexPaths
                .sorted { $0.item < $1.item }
                .compactMap { visibleItems.indices.contains($0.item) ? visibleItems[$0.item] : nil }
        case .list:
            return tableView.selectedRowIndexes
                .compactMap { visibleItems.indices.contains($0) ? visibleItems[$0] : nil }
        }
    }

    /// Selects the item holding `url` and scrolls it into view, centred.
    /// Returns false when the item is not listed.
    @discardableResult
    public func select(url: URL) -> Bool {
        guard let index = FolderScanner.index(of: url, in: visibleItems.map(\.group)) else { return false }
        switch mode {
        case .grid, .filmstrip:
            let ip = IndexPath(item: index, section: 0)
            collectionView.selectionIndexPaths = [ip]
            scrollToCenter(ip, animated: false)
        case .list:
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        notifySelection()
        return true
    }

    /// Selects every item holding one of `urls` (a re-list of the same
    /// folder keeps a multi-selection). Does not scroll, so
    /// an in-place re-list leaves the grid where the user left it.
    @discardableResult
    public func select(urls: [URL]) -> Bool {
        let groups = visibleItems.map(\.group)
        let indices = urls.compactMap { FolderScanner.index(of: $0, in: groups) }
        let carried = carriedKeyRange
        carriedKeyRange = nil
        guard !indices.isEmpty else { return false }
        switch mode {
        case .grid, .filmstrip:
            collectionView.selectionIndexPaths = Set(indices.map { IndexPath(item: $0, section: 0) })
            if let carried,
               let anchor = FolderScanner.index(of: carried.anchor, in: groups),
               let lead = FolderScanner.index(of: carried.lead, in: groups) {
                collectionView.restoreAnchor(IndexPath(item: anchor, section: 0),
                                             lead: IndexPath(item: lead, section: 0))
            }
        case .list:
            tableView.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
        }
        notifySelection()
        return true
    }

    public func selectAll() {
        switch mode {
        case .grid, .filmstrip:
            let all = (0..<visibleItems.count).map { IndexPath(item: $0, section: 0) }
            collectionView.selectionIndexPaths = Set(all)
        case .list:
            tableView.selectAll(nil)
        }
        notifySelection()
    }

    public func deselectAll() {
        switch mode {
        case .grid, .filmstrip:
            collectionView.selectionIndexPaths = []
        case .list:
            tableView.deselectAll(nil)
        }
        notifySelection()
    }

    public func moveSelection(_ delta: Int, clamp: Bool = true) {
        guard !visibleItems.isEmpty else { return }
        let current = selectedItems.first.flatMap { visibleItems.firstIndex(of: $0) } ?? 0
        let target = clamp
            ? max(0, min(visibleItems.count - 1, current + delta))
            : (current + delta + visibleItems.count) % visibleItems.count
        switch mode {
        case .grid, .filmstrip:
            let ip = IndexPath(item: target, section: 0)
            collectionView.selectionIndexPaths = [ip]
            scrollToCenter(ip, animated: false)
        case .list:
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            tableView.scrollRowToVisible(target)
        }
        notifySelection()
    }

    public func applyThumbnailSize() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        if mode == .grid {
            layout.itemSize = NSSize(width: thumbnailPixelSize, height: thumbnailPixelSize + (Prefs.largerChrome ? 48 : 40))
            layout.invalidateLayout()
        }
        applyWheelStep()
    }

    /// One wheel notch moves a third of a grid row (a third of a cell in
    /// the filmstrip). AppKit's default is 10 pt
    /// per line, which is a sliver of a 150 pt thumbnail row and made a
    /// wheel mouse crawl. Precise (trackpad) scrolling ignores these and
    /// stays 1:1.
    static func wheelStep(mode: BrowserViewMode, thumbnailSize: Int, rowHeight: CGFloat) -> CGFloat {
        switch mode {
        case .grid: return ((CGFloat(thumbnailSize) + 40 + 16) / 3).rounded()
        case .filmstrip: return ((filmstripItemSize.width + 12) / 3).rounded()
        case .list: return rowHeight / 3   // = AppKit's default 10 pt for a 28 pt row; unchanged
        }
    }

    func applyWheelStep() {
        let step = Self.wheelStep(mode: mode, thumbnailSize: thumbnailPixelSize, rowHeight: tableView.rowHeight)
        switch mode {
        case .grid:
            gridScrollView.verticalLineScroll = step
        case .filmstrip:
            gridScrollView.horizontalLineScroll = step
        case .list:
            break   // the list's default (10 pt of a 28 pt row) is already a third of a row
        }
    }

    // MARK: - Context menu

    private func makeCollectionContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", #selector(menuOpen(_:))))
        // Rows go up the responder chain to the window controller, which
        // opens the whole selection.
        let editors = ExternalEditorsSubmenu(target: nil)
        editorsSubmenus.append(editors)
        menu.addItem(editors.makeParentItem())
        menu.addItem(makeMenuItem("Reveal in Finder", #selector(menuReveal(_:))))
        // Share ▸ for the selection.
        let share = ShareSubmenu(files: { [weak self] in
            self?.selectedItems.flatMap { ShareSubmenu.files(of: $0.group) } ?? []
        })
        shareSubmenus.append(share)
        menu.addItem(share.makeParentItem())
        // Slideshow…, Batch… and Compare go up the responder chain like the menu
        // bar; the viewer's menu has the same three in the same order (spec 27 P3-12).
        let slideshow = NSMenuItem(title: ShrikeCommand.slideshow.title, action: ShrikeMainMenu.commandAction,
                                   keyEquivalent: "")
        slideshow.representedObject = ShrikeCommand.slideshow.rawValue
        menu.addItem(slideshow)
        let batch = NSMenuItem(title: ShrikeCommand.batch.title, action: ShrikeMainMenu.commandAction,
                               keyEquivalent: "")
        batch.representedObject = ShrikeCommand.batch.rawValue
        menu.addItem(batch)
        // Compare, up the responder chain too.
        let compare = NSMenuItem(title: ShrikeCommand.compare.title, action: ShrikeMainMenu.commandAction,
                                 keyEquivalent: "")
        compare.representedObject = ShrikeCommand.compare.rawValue
        menu.addItem(compare)
        menu.addItem(.separator())
        let rate = NSMenu(title: "Rating")
        for i in 0...5 {
            let title = i == 0 ? "No rating" : String(repeating: "★", count: i)
            let item = NSMenuItem(title: title, action: #selector(menuRate(_:)), keyEquivalent: "")
            item.representedObject = [ShrikeCommand.rate0, .rate1, .rate2, .rate3, .rate4, .rate5][i].rawValue
            item.tag = i
            item.target = self
            rate.addItem(item)
        }
        let rateItem = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        rateItem.submenu = rate
        menu.addItem(rateItem)

        let flagItem = makeMenuItem(ShrikeCommand.toggleFlag.title, #selector(menuFlag(_:)))
        flagItem.representedObject = ShrikeCommand.toggleFlag.rawValue
        menu.addItem(flagItem)
        menu.addItem(.separator())
        // Copy to Folder ▸ · Move to Folder ▸ · Rename… (spec 25 §12.1). The
        // rows go up the responder chain to the Browser controller, like the
        // File menu's.
        for command in [ShrikeCommand.copyToFolder, .moveToFolder] {
            let title = command.title
            let submenu = NSMenu(title: title)
            submenu.delegate = self
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.representedObject = command.rawValue
            parent.submenu = submenu
            menu.addItem(parent)
        }
        let rename = NSMenuItem(title: ShrikeCommand.rename.title, action: ShrikeMainMenu.commandAction,
                                keyEquivalent: "")
        rename.representedObject = ShrikeCommand.rename.rawValue
        // One photo only: with several, the menu leaves it to Batch… (F2 and
        // the File menu still open the batch rename for a selection).
        rename.identifier = Self.contextRenameIdentifier
        MenuKeyHints.applyFunctionKey(to: rename, command: .rename)   // F2 as a real key, no ⌘
        menu.addItem(rename)
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Move to Trash", #selector(menuTrash(_:))))
        return menu
    }

    /// Marks the right-click menu's Rename… row (disabled for several photos).
    static let contextRenameIdentifier = NSUserInterfaceItemIdentifier("browser.contextMenu.rename")

    /// The Browser's destination slots, for the Copy / Move submenus.
    var destinationSlotsProvider: (() -> DestinationSlots?)?

    /// The context menu's titles in order (tests).
    var contextMenuTitlesForTesting: [String] {
        makeCollectionContextMenu().items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// The right-click menus' editor submenus (kept alive: a menu's
    /// delegate is weak).
    private var editorsSubmenus: [ExternalEditorsSubmenu] = []
    /// The right-click menus' Share ▸ helpers (also their delegates).
    private(set) var shareSubmenus: [ShareSubmenu] = []

    private func makeTableContextMenu() -> NSMenu {
        // Same actions, same targets — share the grid menu directly.
        makeCollectionContextMenu()
    }

    private func makeMenuItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuOpen(_ sender: Any?) {
        openSelection()
    }

    @objc private func menuReveal(_ sender: Any?) {
        delegate?.browserContentRequestsRevealInFinder(selectedItems)
    }

    @objc private func menuRate(_ sender: NSMenuItem) {
        delegate?.browserContentRequestsRate(selectedItems, to: sender.tag)
    }

    @objc private func menuFlag(_ sender: Any?) {
        let items = selectedItems
        let anyUnflagged = items.contains { !$0.isFlagged }
        delegate?.browserContentRequestsFlag(items, flag: anyUnflagged)
    }

    @objc private func menuTrash(_ sender: Any?) {
        delegate?.browserContentRequestsTrash(selectedItems)
    }

    // MARK: - Open

    public func openSelection() {
        let items = selectedItems
        guard let first = items.first,
              let index = visibleItems.firstIndex(of: first) else { return }
        delegate?.browserContentDidOpen(visibleItems, startingAt: index)
    }

    // MARK: - Table actions

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        if row >= 0 { openItem(at: row) } else { openSelection() }
    }

    /// Double-click on an item: open it in the paired viewer with the
    /// whole folder as the list.
    public func openItem(at index: Int) {
        guard visibleItems.indices.contains(index) else { return }
        delegate?.browserContentDidOpen(visibleItems, startingAt: index)
    }

    // MARK: - Helpers

    /// Scrolls the item at `ip` to the middle of the view: down the grid,
    /// along the filmstrip. The strip keeps the selected cell centred like
    /// the viewer's filmstrip does; the move is animated except under
    /// Reduce Motion.
    private func scrollToCenter(_ ip: IndexPath, animated: Bool) {
        switch mode {
        case .grid:
            collectionView.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
        case .filmstrip:
            let clip = gridScrollView.contentView
            guard let frame = collectionView.layoutAttributesForItem(at: ip)?.frame,
                  clip.bounds.width > 0 else { return }
            let maxX = max(0, collectionView.frame.width - clip.bounds.width)
            let x = min(max(0, frame.midX - clip.bounds.width / 2), maxX)
            let origin = NSPoint(x: x, y: clip.bounds.origin.y)
            if animated, !ReduceMotion.isOn, view.window != nil {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    clip.animator().setBoundsOrigin(origin)
                }
            } else {
                clip.setBoundsOrigin(origin)
            }
            gridScrollView.reflectScrolledClipView(clip)
        case .list:
            break
        }
    }

    /// Filmstrip: whatever moved the selection (arrow keys, a click near
    /// the edge, a viewer), the selected cell ends up centred.
    private func centerFilmstripSelection() {
        guard mode == .filmstrip else { return }
        let selected = collectionView.selectionIndexPaths
        guard selected.count == 1, let ip = selected.first else { return }
        scrollToCenter(ip, animated: true)
    }

    /// Filmstrip with photos but no selection: selects the first one (the
    /// big picture and the inspector then show it instead of an empty box).
    func selectFirstIfFilmstripIsEmpty() {
        guard mode == .filmstrip, isViewLoaded, !visibleItems.isEmpty,
              collectionView.selectionIndexPaths.isEmpty else { return }
        collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)],
                                     scrollPosition: .centeredHorizontally)
        // A programmatic selection reports nothing to the delegate.
        notifySelection()
    }

    /// A folder just opened: the first photo is selected in every view
    /// (grid, filmstrip, list), so the arrow keys have a place to start.
    /// Nothing happens with a selection already made or an empty folder.
    func selectFirstOnOpen() {
        guard isViewLoaded, let first = visibleItems.first else { return }
        let none = mode == .list ? tableView.selectedRowIndexes.isEmpty
                                 : collectionView.selectionIndexPaths.isEmpty
        guard none else { return }
        selectingFirst = true
        select(url: first.url)
        selectingFirst = false
        // The order may still change (capture-date sort reads files after
        // the first paint): until the user selects something, the re-sort
        // moves the selection to the new first photo.
        firstOnOpenPending = true
    }

    /// True from the automatic first selection of an opened folder until
    /// the user selects anything (or picks another sort order).
    private(set) var firstOnOpenPending = false
    private var selectingFirst = false

    private func selectionIsShown(_ url: URL) -> Bool {
        selectedItems.count == 1 && selectedItems[0].url == url
    }

    /// A selection change is delivered at once, except an EMPTY one: AppKit
    /// reports a step from one photo to the next as "deselected the old"
    /// and then "selected the new", and the first call alone would blank the
    /// big picture and flash the folder in the inspector for one frame (the
    /// 0.2.2 blinking). An empty selection is therefore checked once more at
    /// the end of the event; only if it is still empty is it delivered.
    /// Only AppKit's own callbacks are held back this way: a clear made by
    /// the code itself (a filter, Deselect All) has no second half and is
    /// delivered at once.
    private func notifySelection(fromAppKit: Bool = false) {
        guard !isCarryingSelection else { return }
        if !selectingFirst { firstOnOpenPending = false }
        if fromAppKit && selectedItems.isEmpty {
            guard !emptyCheckPending else { return }
            emptyCheckPending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.emptyCheckPending = false
                    if self.selectedItems.isEmpty && !self.isCarryingSelection { self.deliverSelection() }
                }
            }
            return
        }
        deliverSelection()
    }

    private var emptyCheckPending = false

    private func deliverSelection() {
        // The RAW view belongs to one photo: another selection ends it.
        if let shown = rawShown, selectedItems.count != 1 || selectedItems[0].url != shown.primary {
            rawShown = nil
        }
        centerFilmstripSelection()
        updateFilmstripPreview()
        delegate?.browserContentDidSelect(selectedItems)
    }

    // MARK: - RAW <-> JPEG view switch (⌥R, the RAW chip)

    /// The RAW file of the one selected pair while it is shown instead of
    /// the JPEG; `primary` is the pair's listed file. View only: ratings,
    /// flags, tags and Trash still act on the pair. Another selection ends it.
    private(set) var rawShown: (primary: URL, item: BrowserItem)?

    /// The one selected item when it is a pair: a display file with a RAW
    /// companion (not a RAW-only photo).
    var rawSwitchCandidate: BrowserItem? {
        let selected = selectedItems
        guard selected.count == 1, let item = selected.first,
              !item.group.primaryIsRAW, item.group.rawURL != nil else { return nil }
        return item
    }

    var isShowingRAW: Bool { rawShown != nil }

    /// What the preview, inspector and status bar show: the selection, with
    /// the RAW file in place of its pair while the RAW is shown. The RAW
    /// takes the pair's rating, flag and tags (they apply to both files).
    var shownItems: [BrowserItem] {
        let selected = selectedItems
        guard let shown = rawShown, selected.count == 1, selected[0].url == shown.primary else { return selected }
        var raw = shown.item
        raw.rating = selected[0].rating
        raw.isFlagged = selected[0].isFlagged
        raw.tags = selected[0].tags
        raw.finderTags = selected[0].finderTags
        return [raw]
    }

    /// Shows `raw` (the selected pair's RAW file) in place of the JPEG, or
    /// the JPEG again with nil.
    func showRAW(_ raw: BrowserItem?) {
        if let raw, let pair = rawSwitchCandidate {
            rawShown = (pair.url, raw)
        } else {
            rawShown = nil
        }
        updateFilmstripPreview()
        refreshPairCaptions()
    }

    /// The grid cell of the pair shows the name of the file on screen (spec 27 N5).
    private func refreshPairCaptions() {
        for case let cell as ThumbnailItem in collectionView.visibleItems() {
            guard let url = cell.currentItem?.url else { continue }
            cell.setShownFileName(rawShown?.primary == url ? rawShown?.item.displayName : nil)
        }
    }

    /// A click on a cell's RAW chip: that photo is the selection, then the
    /// switch.
    func rawChipClicked(_ url: URL) {
        if selectedItems.map(\.url) != [url] {
            guard let index = visibleItems.firstIndex(where: { $0.url == url }),
                  mode != .list else { return }
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            notifySelection()
        }
        delegate?.browserContentRequestsRAWSwitch()
    }

    // MARK: - Filmstrip preview

    /// Shows the first selected photo large above the strip (filmstrip mode
    /// only). Cancelled and replaced on every selection change; a result for
    /// a file that is no longer the first selected one is dropped. The
    /// picture comes from the thumbnail cache (no Metal view in the Browser).
    private func updateFilmstripPreview() {
        guard mode == .filmstrip else { return }
        let url = shownItems.first?.url
        guard url != filmstripPreviewURL else { return }
        filmstripPreviewTask?.cancel()
        filmstripPreviewURL = url
        guard let url else {
            filmstripPreview.image = nil
            return
        }
        let cache = services.thumbnailCache
        filmstripPreviewTask = Task { @MainActor [weak self] in
            let image = try? await cache.thumbnail(
                for: FileImageSource(url: url), maxPixelSize: Self.filmstripPreviewPixels)
            guard !Task.isCancelled, let self, self.filmstripPreviewURL == url else { return }
            // The old picture stays until this one is decoded; then one swap.
            // An unreadable file clears it (never the last photo's picture).
            self.filmstripPreview.image = image.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            self.prefetchFilmstripPreviews(around: url)
        }
    }

    /// The next and the previous photo's big picture, decoded ahead
    /// (utility priority), so a step on the arrow keys swaps at once.
    private func prefetchFilmstripPreviews(around url: URL) {
        guard let index = visibleItems.firstIndex(where: { $0.url == url }) else { return }
        let near = [index + 1, index - 1].filter { visibleItems.indices.contains($0) }
        let sources: [any ImageSource] = near.map { visibleItems[$0].imageSource }
        let cache = services.thumbnailCache
        let size = Self.filmstripPreviewPixels
        Task.detached(priority: .utility) { await cache.prefetch(sources, maxPixelSize: size) }
    }

    /// Test seams.
    var filmstripPreviewForTesting: NSImageView { filmstripPreview }
    var filmstripStripFrameForTesting: NSRect { view.layoutSubtreeIfNeeded(); return gridScrollView.frame }
    var filmstripPreviewFrameForTesting: NSRect { view.layoutSubtreeIfNeeded(); return filmstripPreview.frame }
}

// MARK: - NSCollectionViewDataSource

extension BrowserContentViewController: NSCollectionViewDataSource {

    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    public func collectionView(_ collectionView: NSCollectionView,
                               numberOfItemsInSection section: Int) -> Int {
        visibleItems.count
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let raw = collectionView.makeItem(withIdentifier: ThumbnailItem.reuseIdentifier, for: indexPath)
        guard let item = raw as? ThumbnailItem,
              visibleItems.indices.contains(indexPath.item) else { return raw }
        let model = visibleItems[indexPath.item]
        let thumbSize = cellRequestPixelSize
        item.showsNameTooltip = mode == .filmstrip
        item.configure(with: model, pixelSize: thumbSize, cache: services.thumbnailCache)
        if let shown = rawShown, shown.primary == model.url { item.setShownFileName(shown.item.displayName) }
        item.onRAWChip = { [weak self] in self?.rawChipClicked(model.url) }
        configureCount += 1
        madeCells.add(item)
        return item
    }
}

// MARK: - NSCollectionViewDelegate / prefetching

extension BrowserContentViewController: NSCollectionViewDelegate, NSCollectionViewPrefetching {

    public func collectionView(_ collectionView: NSCollectionView,
                               didSelectItemsAt indexPaths: Set<IndexPath>) {
        notifySelection(fromAppKit: true)
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               didDeselectItemsAt indexPaths: Set<IndexPath>) {
        notifySelection(fromAppKit: true)
    }

    // One item per group, the primary's file URL plus the
    // private group type.
    public func collectionView(_ collectionView: NSCollectionView,
                               canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        let ok = indexPaths.allSatisfy { visibleItems.indices.contains($0.item) }
        // A drag takes the whole selection: the press is not a click
        // that narrows it.
        if ok { self.collectionView.noteDragBegan() }
        return ok
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard visibleItems.indices.contains(indexPath.item) else { return nil }
        return PhotoPasteboard.dragItem(for: visibleItems[indexPath.item].group, source: dragSourceID)
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               didEndDisplaying item: NSCollectionViewItem,
                               forRepresentedObjectAt indexPath: IndexPath) {
        (item as? ThumbnailItem)?.cancelLoad()
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               prefetchItemsAt indexPaths: [IndexPath]) {
        let size = cellRequestPixelSize
        let sources: [any ImageSource] = indexPaths.compactMap { ip in
            visibleItems.indices.contains(ip.item)
                ? visibleItems[ip.item].imageSource
                : nil
        }
        let cache = services.thumbnailCache
        Task.detached(priority: .utility) {
            await cache.prefetch(sources, maxPixelSize: size)
        }
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        // Rows that left the prefetch window: drop their queued decodes
        // (one that already started finishes). A row that is on screen
        // keeps its own request, which is not affected.
        let size = cellRequestPixelSize
        let sources: [any ImageSource] = indexPaths.compactMap { ip in
            visibleItems.indices.contains(ip.item) ? visibleItems[ip.item].imageSource : nil
        }
        guard !sources.isEmpty else { return }
        cancelPrefetchObserverForTesting?(sources, size)
        let cache = services.thumbnailCache
        Task.detached(priority: .utility) {
            await cache.cancelPrefetch(sources, maxPixelSize: size)
        }
    }
}

// MARK: - NSTableView data source / delegate

extension BrowserContentViewController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        visibleItems.count
    }

    public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        listMaterializationStatsForTesting?.record(rowView: rowView)
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard visibleItems.indices.contains(row),
              let column = tableColumn else { return nil }
        let item = visibleItems[row]
        listMaterializationStatsForTesting?.recordCell()
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.font = Self.listFont
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false

        switch column.identifier.rawValue {
        case "col.thumb":
            listMaterializationStatsForTesting?.recordThumbnail(for: item.url)
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 4
            image.layer?.masksToBounds = true
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 36),
                image.heightAnchor.constraint(equalToConstant: 24),
            ])
            let cache = services.thumbnailCache
            let source = item.imageSource
            Task { [weak image] in
                do {
                    let cg = try await cache.thumbnail(for: source, maxPixelSize: 80)
                    await MainActor.run { [weak image] in
                        image?.image = NSImage(cgImage: cg,
                                               size: NSSize(width: cg.width, height: cg.height))
                    }
                } catch is CancellationError {
                } catch {
                    // Can't preview: the same glyph as the grid cell (spec 25 §2.2).
                    await MainActor.run { [weak image] in
                        image?.contentTintColor = Badges.brokenFileTint
                        image?.image = Badges.brokenFileGlyph(pointSize: 16)
                    }
                }
            }
        case "col.name":
            let fitted = FittedNameLabel()
            fitted.font = Self.listFont
            fitted.textColor = .labelColor
            fitted.translatesAutoresizingMaskIntoConstraints = false
            fitted.fullName = item.displayName
            fitted.toolTip = item.displayName
            cell.toolTip = item.displayName
            addCellLabel(cell, text: fitted)
        case "col.date":
            text.stringValue = Self.dateFormatter.string(from: item.modificationDate)
            addCellLabel(cell, text: text)
        case "col.dim":
            text.stringValue = listDimensionsText(item)
            addCellLabel(cell, text: text)
        case "col.size":
            text.stringValue = FileSizeText.string(item.fileSize)
            addCellLabel(cell, text: text)
        case "col.rating":
            text.stringValue = Badges.compactStars(item.rating)
            text.textColor = Badges.ratingColor
            text.setAccessibilityLabel(item.rating > 0 ? "\(item.rating) stars" : "No rating")
            addCellLabel(cell, text: text)
        case "col.flag":
            text.stringValue = item.isFlagged ? "⚑" : ""
            text.textColor = Badges.flagColor
            text.setAccessibilityLabel(item.isFlagged ? "Flagged" : "Not flagged")
            addCellLabel(cell, text: text)
        case "col.tags":
            let dots = Badges.dotColors(item.finderTags).map { Badges.dotFill($0) }
            let image = NSImageView(image: Badges.tagDotsImage(dots) ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setAccessibilityLabel(item.tags.isEmpty ? "No tags" : "Tags: " + item.tags.joined(separator: ", "))
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        default:
            break
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView,
                          sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncingSortDescriptors,
              let first = tableView.sortDescriptors.first,
              let key = first.key else { return }
        let newKey: BrowserSortKey
        switch key {
        case "name":   newKey = .name
        case "date":   newKey = .dateModified
        case "size":   newKey = .size
        case "rating": newKey = .rating
        case "dim":    newKey = .dimensions
        default:       newKey = sort.key
        }
        sort = BrowserSort(key: newKey, direction: first.ascending ? .ascending : .descending)
    }

    /// Asked while the user clicks a row (also the selected one); code
    /// that selects rows is not asked. So a click ends the automatic
    /// first-photo selection, as in the grid (`onUserMouseDown`).
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        firstOnOpenPending = false
        return true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
    }

    /// The list drags the same items as the grid.
    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard visibleItems.indices.contains(row) else { return nil }
        return PhotoPasteboard.dragItem(for: visibleItems[row].group, source: dragSourceID)
    }

    private func addCellLabel(_ cell: NSTableCellView, text: NSTextField) {
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = text
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

}

// MARK: - Empty state placeholder

@MainActor
final class BrowserEmptyState: NSView {

    /// Icon 32 pt `secondaryLabelColor`, title 15 pt semibold,
    /// message 13 pt `secondaryLabelColor`, regular button, 12 pt gaps.
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
    private var action: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private lazy var secondary = NSButton(title: "Choose Another Folder…", target: self, action: #selector(secondaryPressed))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = ChromeTypography.font(13)
        subtitle.alignment = .center
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        button.controlSize = .regular
        button.bezelStyle = .push
        let stack = NSStackView(views: [icon, title, subtitle, button, secondary])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        configure(title: "", subtitle: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        configure(symbol: nil, title: title, subtitle: subtitle, buttonTitle: nil, action: nil)
    }

    func configure(symbol: String?, title: String, subtitle: String,
                   buttonTitle: String?, action: (() -> Void)?) {
        secondary.isHidden = true
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.subtitle.isHidden = subtitle.isEmpty
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        self.action = action
    }

    func setSecondary(_ action: (() -> Void)?) { secondaryAction = action; secondary.isHidden = action == nil }
    @objc private func secondaryPressed() { secondaryAction?() }

    var titleText: String { title.stringValue }
    var subtitleText: String? { subtitle.isHidden ? nil : subtitle.stringValue }
    var symbolShown: Bool { !icon.isHidden }
    var buttonTitle: String? { button.isHidden ? nil : button.title }

    @objc private func buttonPressed(_ sender: Any?) { action?() }
}


/// The large picture above the Browser's filmstrip strip.
@MainActor
final class FilmstripPreviewView: NSImageView {
    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        isEditable = false
        setAccessibilityLabel("Selected photo preview")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Never grows the layout with the picture's pixel size.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}


// MARK: - Context menu destinations

extension BrowserContentViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.headerView?.menu {
            refreshHeaderMenuStates(menu)
            return
        }
        if menu.delegate === self, menu.supermenu == nil, !menu.items.isEmpty {
            // The right-click menu itself: draw the bare-key hints.
            MenuKeyHints.apply(to: menu, context: .browser)
            // This controller is the menu's delegate, so it refreshes Share ▸ (it was greyed:
            // the row was built once, with the empty selection of the build).
            for share in shareSubmenus { share.refreshParent() }
            return
        }
        guard let slots = destinationSlotsProvider?() else { return }
        if menu.title == ShrikeCommand.copyToFolder.title {
            ShrikeMainMenu.fillDestinations(menu, command: .copyToFolder, slots: slots, target: nil)
        } else if menu.title == ShrikeCommand.moveToFolder.title {
            ShrikeMainMenu.fillDestinations(menu, command: .moveToFolder, slots: slots, target: nil)
        }
    }
}

/// The list's column header text: 12 pt semibold, `text.secondary` token
/// (spec 27 P3-14; at least 4.5:1 on the header).
final class ListHeaderCell: NSTableHeaderCell {
    static let font = ChromeTypography.font(12, weight: .semibold)

    override init(textCell string: String) {
        super.init(textCell: string)
        font = Self.font
        textColor = ShrikeTokens.textSecondary
    }

    // NSTableHeaderCell ignores `font` / `textColor` when it draws its own title;
    // it draws `attributedStringValue`, so that is where the look lives.
    override var attributedStringValue: NSAttributedString {
        get {
            NSAttributedString(string: stringValue, attributes: [
                .font: Self.font, .foregroundColor: ShrikeTokens.textSecondary,
            ])
        }
        set { super.attributedStringValue = newValue }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("programmatic only") }
}

/// Opt-in observations of real native row/cell work; semantic AX proxies are not views.
/// Tests own this object. Its weak row ledger never retains a table or rendered row.
@MainActor
final class BrowserListMaterializationStats {
    private let rows = NSHashTable<NSTableRowView>.weakObjects()
    private(set) var rowViews = 0
    private(set) var cells = 0
    private(set) var thumbnailRequests = 0
    private(set) var thumbnailURLs: Set<URL> = []
    func record(rowView: NSTableRowView) {
        if !rows.contains(rowView) { rows.add(rowView); rowViews += 1 }
    }
    func recordCell() { cells += 1 }
    func recordThumbnail(for url: URL) { thumbnailRequests += 1; thumbnailURLs.insert(url) }
}

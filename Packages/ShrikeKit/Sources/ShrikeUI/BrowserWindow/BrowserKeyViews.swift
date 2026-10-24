//
//  BrowserKeyViews.swift
//  ShrikeUI
//
//  The grid / filmstrip and list views of the Browser.
//  `keyDown` asks the Browser key map first; only keys it does not map
//  reach `super`, so arrow keys keep AppKit's own column-aware movement
//  and letters never turn into type-select. Double-click opens the item
//  in the paired viewer.
//

import AppKit

/// Grid and filmstrip.
@MainActor
final class BrowserCollectionView: NSCollectionView {

    /// Spec 27 B3: VoiceOver gets the items on screen plus this many each side,
    /// never an item that is not built. (An accessibility query used to build
    /// every one of 1000 items: the app was deaf for ~2 minutes.)
    static let accessibilityOverscan = 10

    /// Items to report: the visible ones, widened by `overscan` positions each side.
    private func accessibleItems(overscan: Int) -> [NSView] {
        let visible = indexPathsForVisibleItems().map(\.item).sorted()
        guard let first = visible.first, let last = visible.last else { return [] }
        let lo = max(0, first - overscan), hi = min(numberOfItems(inSection: 0) - 1, last + overscan)
        guard lo <= hi else { return [] }
        return (lo...hi).compactMap { item(at: IndexPath(item: $0, section: 0))?.view }
    }

    override func accessibilityChildren() -> [Any]? { accessibleItems(overscan: Self.accessibilityOverscan) }
    override func accessibilityVisibleChildren() -> [Any]? { accessibleItems(overscan: 0) }

    /// The true grid size, from the item count and the columns of the first row.
    var accessibleColumnCount: Int {
        let visible = indexPathsForVisibleItems().sorted { $0.item < $1.item }
        guard let first = visible.first, let frame = layoutAttributesForItem(at: first)?.frame else { return 1 }
        var columns = 0
        for path in visible {
            guard let f = layoutAttributesForItem(at: path)?.frame else { continue }
            if abs(f.minY - frame.minY) < 1 { columns += 1 }
        }
        return max(1, columns)
    }

    var accessibleRowCount: Int {
        let count = numberOfItems(inSection: 0)
        return (count + accessibleColumnCount - 1) / accessibleColumnCount
    }

    /// VoiceOver moved the cursor to an item that is off screen: scroll to it.
    func accessibilityScroll(toItem index: Int) {
        guard index >= 0, index < numberOfItems(inSection: 0) else { return }
        if let frame = layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            scrollToVisible(frame)
        }
    }

    /// Returns true when the Browser key map consumed the event.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Double-click on an item.
    var onDoubleClick: ((IndexPath) -> Void)?

    /// Tab / ⇧Tab leave the grid for the next pane (the window's focus ring).
    var onTab: ((Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if BrowserFocusRing.isTab(event), onTab?(event.modifierFlags.contains(.shift)) == true { return }
        if keyHandler?(event) == true { return }
        if let step = Self.shiftArrow(event), extendSelection(by: step) { return }
        super.keyDown(with: event)
    }

    // MARK: Hover (spec 24 §2, the filmstrip view's strip)
    //
    // One tracking area over the whole collection. Only the filmstrip view
    // turns it on; the grid keeps its plain look. The thumbnail under the
    // pointer (not a selected one) shows the ring and the veil.

    /// Set by the Browser in filmstrip mode.
    var hoverEnabled = false {
        didSet {
            guard hoverEnabled != oldValue else { return }
            if !hoverEnabled { clearHover() }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            for case let item as ThumbnailItem in visibleItems() { item.view.window?.invalidateCursorRects(for: item.view) }
        }
    }
    private var hoverTracking: NSTrackingArea?
    private(set) var hoveredIndexPath: IndexPath?
    private var hoverWindowPoint: NSPoint?
    private let hoverObservers = StripObserverBag()
    private var windowObservers = StripObserverBag()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        guard hoverEnabled else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hoverPointer(atWindowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hoverPointer(atWindowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { clearHover() }

    func hoverPointer(atWindowPoint point: NSPoint) {
        guard hoverEnabled else { return }
        hoverWindowPoint = point
        setHovered(indexPathForItem(at: convert(point, from: nil)))
    }

    func clearHover() {
        hoverWindowPoint = nil
        setHovered(nil)
    }

    /// The items moved under a still pointer (scroll, reload): hit-test again.
    func refreshHover() {
        guard hoverEnabled, let point = hoverWindowPoint else { setHovered(nil); return }
        setHovered(indexPathForItem(at: convert(point, from: nil)))
    }

    private func setHovered(_ indexPath: IndexPath?) {
        guard indexPath != hoveredIndexPath else { return }
        if let old = hoveredIndexPath { (item(at: old) as? ThumbnailItem)?.setHovered(false) }
        hoveredIndexPath = indexPath
        if let new = indexPath { (item(at: new) as? ThumbnailItem)?.setHovered(true) }
    }

    override func layout() {
        super.layout()
        if hoverEnabled { refreshHover() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.removeAll()
        clearHover()
        guard let window else { return }
        windowObservers.add(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearHover() }
        })
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverObservers.removeAll()
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        hoverObservers.add(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        })
    }

    // MARK: ⇧-arrows
    //
    // NSCollectionView keeps its own private anchor for ⇧-arrows, and any
    // selection set in code (a re-list after a rating or Q, a view switch)
    // resets it so that ⇧→ shrank the range from its start. The grid now
    // ranges ⇧-arrows itself from the same anchor as a shift-click, with
    // the moving end (`keyLead`) kept beside it.

    enum KeyStep { case left, right, up, down }

    /// ⇧ plus an arrow and no other modifier.
    static func shiftArrow(_ event: NSEvent) -> KeyStep? {
        let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
        guard mods == .shift else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// The moving end of the range, while `keySelection` is the selection.
    private var keyLead: IndexPath?
    /// The selection when the anchor and lead were last set; any other
    /// selection (a plain arrow, a select-all) makes them guesses again.
    private var keySelection: Set<IndexPath>?

    /// The range the next ⇧-arrow changes: the anchor, the moving end and
    /// the items kept beside the range. When the selection changed in
    /// another way, the anchor is the shift-click anchor if it is still
    /// selected (else the first selected item) and the moving end is the
    /// far end of the run of selected items through it.
    var keyRange: (anchor: IndexPath, lead: IndexPath)? {
        resolvedKeyRange().map { ($0.anchor, $0.lead) }
    }

    /// True when the moving end is known (the selection is the one the
    /// last click or ⇧-arrow made); false after a select-all or any other
    /// change, where `keyRange` only guesses.
    var hasKeyMovingEnd: Bool {
        guard let keySelection, keySelection == selectionIndexPaths,
              let anchor = selectionAnchor, let lead = keyLead else { return false }
        return keySelection.contains(anchor) && keySelection.contains(lead)
    }

    private func resolvedKeyRange() -> (anchor: IndexPath, lead: IndexPath, base: Set<IndexPath>)? {
        let current = selectionIndexPaths
        guard let first = current.min() else { return nil }
        if keySelection == current, let anchor = selectionAnchor, let lead = keyLead,
           current.contains(anchor), current.contains(lead) {
            return (anchor, lead, anchorBase)
        }
        let anchor = selectionAnchor.flatMap { current.contains($0) ? $0 : nil } ?? first
        func at(_ item: Int) -> IndexPath { IndexPath(item: item, section: anchor.section) }
        var end = anchor.item
        while current.contains(at(end + 1)) { end += 1 }
        if end == anchor.item {
            while current.contains(at(end - 1)) { end -= 1 }
        }
        let lead = at(end)
        return (anchor, lead, current.subtracting(Self.range(anchor, lead)))
    }

    private static func range(_ a: IndexPath, _ b: IndexPath) -> Set<IndexPath> {
        Set((min(a.item, b.item)...max(a.item, b.item)).map { IndexPath(item: $0, section: a.section) })
    }

    /// Moves the lead one item (← →) or one row (↑ ↓) and selects from the
    /// anchor to it, plus the ⌘-clicked items beside the range. False (so
    /// AppKit handles the key) with nothing selected, or ↑ ↓ in the
    /// filmstrip.
    @discardableResult
    func extendSelection(by step: KeyStep) -> Bool {
        let count = numberOfSections > 0 ? numberOfItems(inSection: 0) : 0
        guard count > 0, let range = resolvedKeyRange() else { return false }
        let horizontal = (collectionViewLayout as? NSCollectionViewFlowLayout)?.scrollDirection == .horizontal
        let delta: Int
        switch step {
        case .left: delta = -1
        case .right: delta = 1
        case .up, .down:
            if horizontal { return false }
            delta = (step == .up ? -1 : 1) * itemsPerRow(count: count)
        }
        let item = min(max(range.lead.item + delta, 0), count - 1)
        let lead = IndexPath(item: item, section: range.lead.section)
        selectionAnchor = range.anchor
        anchorBase = range.base
        apply(selection: range.base.union(Self.range(range.anchor, lead)))
        keyLead = lead
        keySelection = selectionIndexPaths
        reveal(lead, horizontal: horizontal)
        return true
    }

    /// Set by the Browser: brings the moving end into view (centred, as the
    /// plain arrow keys do). Without it the item scrolls to the nearest edge.
    var revealLead: ((IndexPath) -> Void)?

    private func reveal(_ lead: IndexPath, horizontal: Bool) {
        if let revealLead { revealLead(lead); return }
        scrollToItems(at: [lead], scrollPosition: horizontal ? .nearestHorizontalEdge : .nearestVerticalEdge)
    }

    /// Items in the grid's first row (the step of ⇧↑ / ⇧↓).
    private func itemsPerRow(count: Int) -> Int {
        guard let first = layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else { return 1 }
        var n = 1
        while n < count, let frame = layoutAttributesForItem(at: IndexPath(item: n, section: 0))?.frame,
              abs(frame.minY - first.minY) < 1 {
            n += 1
        }
        return n
    }

    // MARK: Shift-click range

    /// The item the last plain or ⌘-click landed on: a shift-click selects
    /// from here to the clicked item, as the list view does.
    private(set) var selectionAnchor: IndexPath?
    /// What stays selected beside the range: the ⌘-clicked items from
    /// before the anchor was set (empty after a plain click).
    private var anchorBase: Set<IndexPath> = []

    /// A click anywhere in the view is the user's choice (it ends the
    /// automatic first-photo selection even when it hits the selected cell).
    var onUserMouseDown: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = indexPathForItem(at: point) {
            onUserMouseDown?()
            pendingSingleSelect = nil
            dragBegan = false
            if !selectionIndexPaths.contains(hit) {
                apply(selection: [hit])
                noteClick(on: hit, command: false)
            }
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        onUserMouseDown?()
        let point = convert(event.locationInWindow, from: nil)
        let hit = indexPathForItem(at: point)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.clickCount == 1, let hit, mods.contains(.shift), !mods.contains(.command) {
            // NSCollectionView's own shift-click adds just the one item.
            window?.makeFirstResponder(self)
            extendSelection(to: hit)
            return
        }
        // "Single-click: select one". A
        // plain click on a photo inside a multi-selection keeps them all
        // on mouse-down (so a drag takes them all) and selects just that
        // photo on mouse-up, as Finder does.
        let plain = mods.intersection([.shift, .command, .control, .option]).isEmpty
        pendingSingleSelect = nil
        dragBegan = false
        // A plain click on a photo that is not selected selects only it, in
        // every view (grid, filmstrip). Done here, so it does not depend on
        // how AppKit reads the modifier state of the press (⌘ and ⇧ keep
        // their toggle and range meaning above and in AppKit).
        if event.clickCount == 1, plain, let hit, !selectionIndexPaths.contains(hit),
           !selectionIndexPaths.isEmpty {
            apply(selection: [hit])
        }
        let narrowTo: IndexPath? = if event.clickCount == 1, plain, let hit,
            selectionIndexPaths.count > 1, selectionIndexPaths.contains(hit) { hit } else { nil }
        if let track = mouseTrackingForTesting { track(event) } else { super.mouseDown(with: event) }
        if let narrowTo {
            // NSCollectionView may track the press itself and return after
            // the mouse-up (or when a drag starts); else the mouse-up comes
            // to `mouseUp` below. A drag never narrows (`noteDragBegan`).
            switch NSApp.currentEvent?.type {
            case .leftMouseUp?: narrowSelection(to: narrowTo)
            case .leftMouseDragged?: break
            default: pendingSingleSelect = narrowTo
            }
        }
        if event.clickCount == 1 { noteClick(on: hit, command: mods.contains(.command)) }
        guard event.clickCount == 2 else { return }
        if let hit { onDoubleClick?(hit) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let target = pendingSingleSelect { narrowSelection(to: target) }
        pendingSingleSelect = nil
    }

    /// The clicked photo waiting for its mouse-up.
    private var pendingSingleSelect: IndexPath?
    /// A drag of the selection started during this press: it keeps the
    /// whole selection (the Browser hears `canDragItemsAt`).
    private(set) var dragBegan = false
    func noteDragBegan() {
        dragBegan = true
        pendingSingleSelect = nil
        clearHover()
    }
    /// Test seam: stands in for AppKit's own press tracking.
    var mouseTrackingForTesting: ((NSEvent) -> Void)?

    /// Mouse-up without a drag: the clicked photo alone stays selected;
    /// the delegate hears it as it does for a click.
    private func narrowSelection(to target: IndexPath) {
        guard !dragBegan, selectionIndexPaths.contains(target), selectionIndexPaths.count > 1 else { return }
        apply(selection: [target])
        selectionAnchor = target
        anchorBase = []
        keyLead = target
        keySelection = selectionIndexPaths
    }

    /// A plain or ⌘-click (after AppKit applied it) moves the anchor.
    func noteClick(on hit: IndexPath?, command: Bool) {
        guard let hit else {
            if !command { selectionAnchor = nil; anchorBase = [] }
            keyLead = nil
            keySelection = nil
            return
        }
        selectionAnchor = hit
        anchorBase = command ? selectionIndexPaths.subtracting([hit]) : []
        keyLead = hit
        keySelection = selectionIndexPaths
    }

    /// A view switch (list → grid) carries the anchor over;
    /// nil leaves the first selected item as the anchor. A
    /// re-list also carries the moving end of a ⇧-arrow range.
    func restoreAnchor(_ anchor: IndexPath?, lead: IndexPath? = nil) {
        selectionAnchor = anchor
        anchorBase = []
        keyLead = nil
        keySelection = nil
        guard let anchor, let lead, selectionIndexPaths.contains(anchor), selectionIndexPaths.contains(lead) else { return }
        anchorBase = selectionIndexPaths.subtracting(Self.range(anchor, lead))
        keyLead = lead
        keySelection = selectionIndexPaths
    }

    /// Shift-click: the selection becomes the range from the anchor to
    /// `target`, plus the ⌘-clicked items kept beside it, so a second
    /// shift-click nearer the anchor shrinks the range (Finder list view,
    /// NSTableView). Without an anchor that is still selected (the keys
    /// moved the selection), the first selected item is the anchor. The
    /// delegate hears the change as it does for a click.
    func extendSelection(to target: IndexPath) {
        var anchor = selectionAnchor
        if let current = anchor, !selectionIndexPaths.contains(current) { anchor = nil }
        if anchor == nil {
            anchor = selectionIndexPaths.min()
            anchorBase = []
        }
        guard let anchor else {
            selectionAnchor = target
            anchorBase = []
            apply(selection: [target])
            keyLead = target
            keySelection = selectionIndexPaths
            return
        }
        selectionAnchor = anchor
        apply(selection: anchorBase.union(Self.range(anchor, target)))
        keyLead = target
        keySelection = selectionIndexPaths
        reveal(target, horizontal: (collectionViewLayout as? NSCollectionViewFlowLayout)?.scrollDirection == .horizontal)
    }

    private func apply(selection new: Set<IndexPath>) {
        let old = selectionIndexPaths
        let removed = old.subtracting(new)
        let added = new.subtracting(old)
        if !removed.isEmpty {
            deselectItems(at: removed)
            delegate?.collectionView?(self, didDeselectItemsAt: removed)
        }
        if !added.isEmpty {
            selectItems(at: added, scrollPosition: [])
            delegate?.collectionView?(self, didSelectItemsAt: added)
        }
    }

    /// New contents (sort, filter, folder): the old anchor means nothing.
    override func reloadData() {
        selectionAnchor = nil
        anchorBase = []
        keyLead = nil
        keySelection = nil
        // The cells are rebuilt (their hover resets on reuse); the next
        // layout re-hit-tests under a still pointer.
        hoveredIndexPath = nil
        super.reloadData()
    }
}

/// List view.
@MainActor
final class BrowserTableView: NSTableView {

    /// Native AppKit owns semantic rows/children, including offscreen rows.
    var accessibleRowCount: Int { numberOfRows }

    /// VoiceOver moved to a row that is off screen: scroll to it, then its row view exists.
    func accessibilityScroll(toRow row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        scrollRowToVisible(row)
    }

    /// Returns true when the Browser key map consumed the event.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Tab / ⇧Tab leave the list for the next pane (the window's focus ring).
    var onTab: ((Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if BrowserFocusRing.isTab(event), onTab?(event.modifierFlags.contains(.shift)) == true { return }
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Tab order of the Browser (audit on-screen M6): photos → search → sidebar → info
/// panel → photos. Tab used to stay in the grid for ever, so the sidebar, the
/// search field and the info panel could not be reached from the keyboard.
@MainActor
enum BrowserFocusRing {
    /// A plain Tab or ⇧Tab (no ⌘ ⌃ ⌥).
    static func isTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// The pane after (or before) `current`, wrapping. `current` may be inside one of the
    /// entries (the field editor of the search field, a row of the sidebar).
    static func next(from current: NSResponder?, in ring: [NSView], backward: Bool) -> NSView? {
        guard !ring.isEmpty else { return nil }
        let index = ring.firstIndex { entry in
            guard let view = current as? NSView else { return false }
            return view === entry || view.isDescendant(of: entry)
        } ?? ring.firstIndex { entry in
            // The field editor is an NSTextView whose delegate is the search field.
            (current as? NSTextView)?.delegate === entry
        }
        guard let index else { return ring.first }
        return ring[(index + (backward ? ring.count - 1 : 1)) % ring.count]
    }

    /// The first view inside `root` a keyboard user can land on.
    static func firstKeyView(in root: NSView) -> NSView? {
        if root.canBecomeKeyView, !root.isHidden { return root }
        for sub in root.subviews where !sub.isHidden {
            if let hit = firstKeyView(in: sub) { return hit }
        }
        return nil
    }
}

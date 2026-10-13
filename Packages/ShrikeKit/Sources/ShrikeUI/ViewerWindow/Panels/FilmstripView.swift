//
//  FilmstripView.swift
//  ShrikeUI
//
//  Layer-backed AppKit horizontal filmstrip of neighbor thumbnails.
//
//  Single component, two modes:
//   * `.windowed`    — docked under the canvas, height from `Prefs.filmstripHeightPt`,
//                      opaque `NSColor.windowBackgroundColor` background
//                      ("opaque panel, no blur"). Achieved by hosting a plain NSView
//                      backdrop instead of the visual-effect chassis.
//   * `.fullscreen`  — top edge-hover overlay, 88 pt, HUD-material blur.
//                      Returns to 88 pt total / 72 pt cells now
//                      that the 20 pt pin strip has been replaced by a corner
//                      overlay.
//
//  Both modes share thumbnail loading, selection, scroll-wheel scrubbing,
//  and click-to-jump. The enclosing controller (`ViewerContentView`) owns
//  visibility; this view is a dumb renderer.
//
//  Perf contract:
//   * `updateNeighbors` does in-place diffing keyed on global index. Cells
//     that survive the window shift keep their loaded NSImage + position.
//     Only cells leaving/entering the window churn.
//   * Thumbnail pixel size tracks `cellSize × backingScaleFactor` — not
//     hardcoded. Keeps Retina sharp without over-decoding on 1× displays.
//   * Cells are variable-width: height = cellSize, width = cellSize × aspect
//     clamped [0.5×, 1.6×] (Apple Photos / Lightroom convention). Aspect is
//     derived from the loaded thumbnail's own CGImage when possible
//     (eliminates the second header-read round-trip
//     that made portrait detection visibly slow). Header-read stays as the
//     pre-decode fallback so the cell isn't square-shaped for 100 ms while
//     the thumb decodes.
//

import AppKit
import ShrikeCore
import ImageIO
import os
import ShrikeIO

@MainActor
final class FilmstripView: HUDSurfaceView {

    // MARK: - Empty state

    /// True while the viewer shows its empty state: the view stays hidden
    /// whatever its own show / hide code asks for, and the asked-for state
    /// comes back when the empty state goes away.
    var isSuppressed = false {
        didSet {
            super.isHidden = wantsHidden || isSuppressed
            if isSuppressed { clearHover() }
        }
    }
    private var wantsHidden = false
    override var isHidden: Bool {
        get { super.isHidden }
        set {
            wantsHidden = newValue
            super.isHidden = newValue || isSuppressed
            if newValue || isSuppressed { clearHover() }
        }
    }

    enum Mode: Sendable, Hashable {
        /// Top edge-hover overlay. HUD blur. 88 pt default height.
        case fullscreen
        /// Docked under the canvas. Opaque background. Height per pref.
        case windowed
    }

    private let spacing: CGFloat = 8
    /// Fullscreen overlay total height (88 pt now that the pin strip is gone).
    private static let fullscreenTotalHeight: CGFloat = 88
    /// Fullscreen cell size (72×72 pt).
    private static let fullscreenCellSize: CGFloat = 72
    /// Fullscreen content-area top/bottom insets. 88 total − 72 cell − 8 top
    /// − 8 bottom = 0, so top/bottom padding is (88 − 72) / 2 = 8 pt each.
    private static let fullscreenContentPadTop: CGFloat = 8
    private static let fullscreenContentPadBottom: CGFloat = 8

    /// Opaque backdrop used in windowed mode ("opaque panel,
    /// no blur"). In full screen the surface's HUD material (glass on
    /// macOS 26) shows instead.
    private let opaqueBackdrop = TokenBackgroundView(fillColor: HUDGlass.opaqueSurfaceColor)
    /// A 1 pt hairline (white at 8 %) between the photo and
    /// the docked strip.
    private let topHairline = TokenBackgroundView(fillColor: NSColor.white.withAlphaComponent(0.08))

    private let scrollView: FilmstripScrollView
    private let stackView = StripStackView()

    /// Pin glyph far-corner convention. Top-right, 8 pt inset.
    /// Replaces the 20 pt pin strip
    private let pinOverlay: PinCornerOverlay

    /// Index-keyed cell map for in-place diffing during `updateNeighbors`.
    /// Keyed on the image's global folder index — stable across window
    /// shifts, so when the user advances one image we only churn the two
    /// cells leaving / entering the 21-wide window.
    private var cellsByIndex: [Int: ThumbCell] = [:]
    private var currentGlobalIndex: Int = 0

    /// Aspect-ratio memory keyed on global image index. Survives window
    /// shifts so cells that leave and re-enter the neighbor window don't
    /// flash 1:1 while the thumbnail redecodes. Populated by
    /// `ThumbCell.applyAspectFromThumb(…)` via `aspectAppliedSink`, read
    /// on cell construction to eager-set the width constraint before
    /// the first thumbnail decode lands. Fix #3 subpart.
    ///
    /// Evicted by `pruneAspectCache(around:)` to `±radius × 3` around
    /// the current index so we don't grow unbounded across a long
    /// navigation session.
    private var recentAspects: [Int: CGFloat] = [:]

    /// Timestamp of the last selection change (via `CACurrentMediaTime`).
    /// Used to skip the centering animation when two selections land
    /// within 150 ms of each other (arrow-key repeat rate, ~10 Hz).
    private var lastSelectionAt: CFTimeInterval = 0

    /// Fired when the user clicks a thumb. Passes the *global* image index
    /// (the index into the viewer's folder list), not a filmstrip-local
    /// one. The enclosing controller wires this to `navigate(to:)`.
    /// No new `ViewerAction` case is needed.
    var onSelectGlobal: ((Int) -> Void)?
    /// The viewer's context menu for a right-click on a cell (spec 25 §12.2).
    var contextMenuProvider: (() -> NSMenu?)?

    /// Rating + flag for a global index; nil draws none.
    var marksProvider: ((Int) -> (rating: Int, flagged: Bool))?

    /// The group at a global index, for drag out; nil
    /// turns dragging off.
    var groupProvider: ((Int) -> ImageGroup?)?
    /// This viewer's id on the private drag type.
    let dragSourceID = UUID().uuidString

    /// The drag item for the cell at `globalIndex`: the primary's file
    /// URL plus the private group type.
    func dragItem(for globalIndex: Int) -> NSPasteboardItem? {
        guard let group = groupProvider?(globalIndex) else { return nil }
        return PhotoPasteboard.dragItem(for: group, source: dragSourceID)
    }

    /// Test seam: the marks the cell at `globalIndex` draws.
    func cellMarksForTesting(_ globalIndex: Int) -> (rating: Int, flagged: Bool, flagDrawn: Bool, starsDrawn: Bool)? {
        guard let cell = cellsByIndex[globalIndex] else { return nil }
        return (cell.shownMarks.rating, cell.shownMarks.flagged, cell.flagDrawnForTesting, cell.starsDrawnForTesting)
    }

    /// Test seam: the file each live cell shows, by global index.
    var cellFileNamesForTesting: [Int: String] {
        cellsByIndex.mapValues { ($0.source as? FileImageSource)?.url.lastPathComponent ?? $0.source.id }
    }

    /// Test seam: the cell view drawn for `globalIndex`, if it is built.
    func cellViewForTesting(_ globalIndex: Int) -> NSView? { cellsByIndex[globalIndex] }

    /// Re-reads `marksProvider` for every live cell.
    func refreshMarks() {
        for (idx, cell) in cellsByIndex {
            let marks: (rating: Int, flagged: Bool) = marksProvider?(idx) ?? (0, false)
            cell.setMarks(rating: marks.rating, flagged: marks.flagged)
        }
    }

    /// Fired when the user wheel-scrolls over the filmstrip itself.
    /// Delta is accumulated pixels (summed across precise / imprecise
    /// deltas). Positive = advance, negative = retreat.
    var onScrollScrub: ((Int) -> Void)?

    /// Fired when the user clicks the pin glyph in fullscreen mode.
    /// The enclosing controller toggles the pref + its `pinnedPanels`
    /// set. In windowed mode the glyph is hidden and this is unused.
    var onTogglePin: (() -> Void)?

    /// Optional generic action dispatcher for completeness (unused).
    var actionDispatcher: ((ViewerAction) -> Void)?

    /// Current render mode. Changing this re-lays-out the material /
    /// edge insets. Does NOT reload thumbs.
    private(set) var mode: Mode = .fullscreen

    /// Current pin state (drives the pin glyph's filled/unfilled variant).
    /// The enclosing controller keeps authoritative pin state; this is a
    /// display-only mirror.
    private(set) var pinned: Bool = false

    /// Height of a cell in points. In fullscreen mode this is 72 pt
    /// (the pin strip is gone). In windowed mode it's derived from
    /// `Prefs.filmstripHeightPt` minus top+bottom padding.
    private var cellSize: CGFloat = 72

    init() {
        self.scrollView = FilmstripScrollView()
        self.pinOverlay = PinCornerOverlay(
            identifierSuffix: "filmstrip",
            panelName: "Filmstrip",
            appearance: .fullscreenHUD
        )
        super.init(frame: .zero)
        wantsLayer = true
        // The glass panel's corners clip the thumbnails.
        scrollView.filmstrip = self
        setupBackdrops()
        setupLayout()
        installHoverObservers()
        stackView.onLaidOut = { [weak self] in self?.refreshHover() }
        setupPinOverlay()
        applyMode()
        // Install the aspect-cache hook — every time a cell settles its
        // aspect from a delivered thumbnail, remember it so subsequent
        // window shifts don't redecode from 1:1.
        //
        // Note: `ThumbCell.aspectCacheHook` is static and shared across
        // all FilmstripViews. In tests we occasionally spin multiple
        // strips (one per test) — the weak-capture pattern keeps this
        // safe: whichever strip was constructed last owns the hook, and
        // an old strip's stale cache entries are harmless since they
        // only affect that strip's own cells.
        ThumbCell.aspectCacheHook = { [weak self] idx, aspect in
            Task { @MainActor [weak self] in
                self?.recentAspects[idx] = aspect
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Mode + height

    /// Set the render mode (windowed docked vs. fullscreen overlay). Called
    /// by `ViewerContentView` when entering / exiting fullscreen.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        applyMode()
        // Reflow — cells keep their aspect, only the container styling
        // changes.
        refreshCellSizes()
    }

    /// Set the cell size (drives height; cell width is `cellSize × aspect`).
    /// Called by the enclosing controller from `Prefs.filmstripHeightPt`
    /// observers. Clamped to a reasonable range.
    func setCellSize(_ pt: CGFloat) {
        let clamped = min(108, max(48, pt))
        guard abs(clamped - cellSize) > 0.5 else { return }
        cellSize = clamped
        refreshCellSizes()
    }

    /// Update the pin glyph state (filled vs. unfilled). Called by the
    /// enclosing controller; does not mutate any pref.
    func setPinned(_ flag: Bool) {
        pinned = flag
        pinOverlay.setPinned(flag)
    }

    /// Width of the strip's visible scrolling region in points.
    /// Returns 0 before the view has been sized (e.g. first call to
    /// `updateFilmstrip(centeredOn:)` during window construction, before
    /// AppKit has run a layout pass). Callers must treat 0 as "unknown —
    /// use a fallback radius" and re-query on the next navigation.
    ///
    /// Used by `ViewerWindow.updateFilmstrip(centeredOn:)` to size the
    /// neighbor window to cover the visible strip — a hardcoded radius
    /// left half of an ultra-wide display empty (the fullscreen filmstrip
    /// showed thumbnails only in the left half of the screen).
    func visibleWidth() -> CGFloat {
        scrollView.contentView.bounds.width
    }

    /// Current cell height in points. Width per cell is
    /// `height × aspect` clamped to `[0.5×, 1.6×]`, so the expected
    /// *average* cell width is `cellSize × 1.0`. Used by callers that
    /// need to estimate how many cells fit in a given strip width.
    func currentCellSize() -> CGFloat { cellSize }

    private func setupBackdrops() {
        opaqueBackdrop.translatesAutoresizingMaskIntoConstraints = false

        // The full-screen blur is the surface's own material.

        addSubview(opaqueBackdrop)
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        topHairline.isHidden = true
        addSubview(topHairline)
        NSLayoutConstraint.activate([
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: 1),
            opaqueBackdrop.topAnchor.constraint(equalTo: topAnchor),
            opaqueBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            opaqueBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            opaqueBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func applyMode() {
        switch mode {
        case .fullscreen:
            // 88 pt total, 72 pt cells, 8 pt top/bottom pad.
            // The pin strip is gone; cells no longer need
            // to leave room for a reserved strip.
            cellSize = Self.fullscreenCellSize
            stackView.edgeInsets = NSEdgeInsets(
                top: Self.fullscreenContentPadTop,
                left: 16,
                bottom: Self.fullscreenContentPadBottom,
                right: 16
            )
            opaqueBackdrop.isHidden = true
            topHairline.isHidden = true
            setShowsMaterial(true)
            pinOverlay.setAppearance(.fullscreenHUD)
            pinOverlay.isHidden = false
            // The scroller ends before the 36 pt pin slot.
            scrollViewTrailing?.constant = -Self.pinSlotWidth
        case .windowed:
            // Windowed mode is inside a titled window calls
            // for an opaque panel with no blur.
            stackView.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
            opaqueBackdrop.isHidden = false
            topHairline.isHidden = false
            setShowsMaterial(false)
            pinOverlay.setAppearance(.windowed)
            // Pins exist only in full screen; ⌘K shows or
            // hides the docked strip in a window.
            pinOverlay.isHidden = true
            scrollViewTrailing?.constant = 0
        }
    }

    private func refreshCellSizes() {
        for cell in cellsByIndex.values {
            cell.setCellSize(cellSize)
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = spacing
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        // Scroll view fills the panel; in full screen it ends before the
        // 36 pt pin slot.
        let trailing = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        scrollViewTrailing = trailing
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    /// The pin's own trailing slot, outside the scroller.
    static let pinSlotWidth: CGFloat = 36
    private var scrollViewTrailing: NSLayoutConstraint?

    private func setupPinOverlay() {
        // 28×28 hit area, centred in the 36 pt trailing
        // slot, centred vertically.
        pinOverlay.translatesAutoresizingMaskIntoConstraints = false
        pinOverlay.delegate = self
        addSubview(pinOverlay)
        NSLayoutConstraint.activate([
            pinOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinOverlay.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.pinSlotWidth / 2),
            pinOverlay.widthAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
            pinOverlay.heightAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
        ])
    }

    /// Test seam — the thumbnail scroller's frame in strip coordinates.
    internal var scrollerFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return scrollView.frame }

    // MARK: - Public API

    /// Rebuild the strip from a neighbor window. The neighbor indices map
    /// directly to the viewer's global folder list. Each cell stores its
    /// global index and emits it on click.
    ///
    /// Fix A — in-place diffing on global index. Surviving cells keep
    /// their loaded NSImage + width constraint. Only cells leaving the
    /// window are removed; only new cells get a thumbnail request. This
    /// makes forward/backward navigation O(1) cell churn instead of
    /// O(neighbor-count), eliminating the per-keypress rebuild lag.
    /// Spec 27 B4: the file behind a cell changed (turned, saved, reverted,
    /// undone). Its thumbnail was just evicted: ask again and let the cell take the
    /// new aspect. The cell keeps its old picture until the new one arrives (no
    /// blank flash); other cells are untouched. Returns how many cells asked.
    @discardableResult
    func reloadThumbnail(for url: URL, services: ShrikeServices) -> Int {
        let target = GroupList.canonical(url)
        let pixelSize = Int(ceil(cellSize * backingScaleFactorForRequests()))
        var asked = 0
        for cell in cellsByIndex.values {
            guard let file = cell.source as? FileImageSource, GroupList.canonical(file.url) == target else { continue }
            cell.requestThumbnail(services: services, fallbackFor: cell.source, maxPixelSize: pixelSize)
            asked += 1
        }
        return asked
    }

    /// Test seam: the aspect and frame of the cell showing `url`.
    func cellAspectForTesting(url: URL) -> (aspect: CGFloat, frame: CGRect)? {
        let target = GroupList.canonical(url)
        for cell in cellsByIndex.values {
            if let file = cell.source as? FileImageSource, GroupList.canonical(file.url) == target {
                layoutSubtreeIfNeeded()
                return (cell.aspectForTesting, cell.frame)
            }
        }
        return nil
    }

    func updateNeighbors(
        _ neighbors: [(idx: Int, source: any ImageSource)],
        current: Int,
        services: ShrikeServices
    ) {
        let scale = backingScaleFactorForRequests()
        let pixelSize = Int(ceil(cellSize * scale))
        let incomingIndices = Set(neighbors.map(\.idx))
        let incomingIDs = Dictionary(neighbors.map { ($0.idx, $0.source.id) },
                                     uniquingKeysWith: { a, _ in a })

        // 1. Remove cells whose indices left the window, and cells whose
        //    index now holds another photo. After a delete (or an undo)
        //    the list shifts: the same index points at the next photo, so
        //    a cell kept by index alone would keep showing the deleted
        //    one's thumbnail and the strip would never lose a cell.
        var listShifted = false
        for (idx, cell) in cellsByIndex
        where !incomingIndices.contains(idx) || incomingIDs[idx] != cell.source.id {
            if incomingIndices.contains(idx) { listShifted = true }
            stackView.removeArrangedSubview(cell)
            cell.removeFromSuperview()
            cell.cancelThumbnail()
            cellsByIndex.removeValue(forKey: idx)
        }
        // Cached aspects are keyed by index: stale once the list shifted.
        if listShifted { recentAspects.removeAll() }

        // 2. For each incoming slot, ensure a cell exists at the right
        //    position in the stack. Survivors just shift position;
        //    new indices get freshly-constructed cells and thumbnail
        //    requests.
        for (offset, pair) in neighbors.enumerated() {
            if let existing = cellsByIndex[pair.idx] {
                // Cell survived — reorder if its current stack position
                // differs from its new offset.
                let currentPos = stackView.arrangedSubviews.firstIndex(of: existing)
                if currentPos != offset {
                    stackView.removeArrangedSubview(existing)
                    stackView.insertArrangedSubview(existing, at: offset)
                }
            } else {
                let cell = ThumbCell(globalIndex: pair.idx, source: pair.source)
                cell.setCellSize(cellSize)
                cell.isSelected = (pair.idx == current)
                cell.onClick = { [weak self] globalIndex in
                    self?.onSelectGlobal?(globalIndex)
                }
                cell.dragItemProvider = { [weak self] globalIndex in
                    self?.dragItem(for: globalIndex)
                }
                cell.onDragBegan = { [weak self] in self?.clearHover() }
                cell.onContextMenu = { [weak self] in self?.contextMenuProvider?() }
                // Fix #3 — if this index was previously in the neighbor
                // window and had its aspect resolved, seed the cell's
                // width constraint from the cached value right now so
                // we don't flash a 1:1 square while the thumbnail
                // redecodes. Prevents post-thumb re-width from shifting
                // neighbors under a just-centered selection.
                if let cachedAspect = recentAspects[pair.idx] {
                    cell.overrideAspectForTesting(cachedAspect)
                }
                stackView.insertArrangedSubview(cell, at: offset)
                cellsByIndex[pair.idx] = cell
                // The hand cursor for a cell that scrolled in.
                window?.invalidateCursorRects(for: cell)
                cell.requestThumbnail(
                    services: services,
                    fallbackFor: pair.source,
                    maxPixelSize: pixelSize
                )
            }
        }

        // 3. Normalise selection state across all surviving + new cells.
        for (idx, cell) in cellsByIndex {
            cell.isSelected = (idx == current)
        }
        refreshMarks()
        currentGlobalIndex = current

        // 4. Re-center on rebuild — guarantees the selected cell is
        //    visible even if the window shifted. Skip animation if a
        //    rebuild is firing on top of a very recent selection
        //    (arrow-key burst).
        centerSelectedCell(animated: shouldAnimateSelection())
        // Cells came and went: the hover follows the pointer again.
        refreshHover()

        // 5. Evict far-out aspect cache entries so we don't grow
        //    unbounded across a long navigation session. Keep ±(count×3)
        //    around the current index — roughly 60 entries for a 21-wide
        //    window, trivial memory but enough that stepping back to a
        //    recently-visited image re-uses its cached aspect.
        pruneAspectCache(around: current, radius: max(neighbors.count, 1) * 3)
    }

    /// Keep `recentAspects` from growing unbounded. Evicts entries whose
    /// index is further than `radius` from `center`.
    private func pruneAspectCache(around center: Int, radius: Int) {
        guard recentAspects.count > radius * 4 else { return }
        let lo = center - radius
        let hi = center + radius
        recentAspects = recentAspects.filter { (idx, _) in idx >= lo && idx <= hi }
    }

    /// Highlight the cell whose `globalIndex == index` and scroll it into
    /// view. Called on every `beginNavigation()` (not on decode complete)
    /// so the selection follows intent, not decode success.
    func updateSelection(_ globalIndex: Int) {
        let animate = shouldAnimateSelection()
        lastSelectionAt = CACurrentMediaTime()
        currentGlobalIndex = globalIndex
        for (idx, cell) in cellsByIndex {
            cell.isSelected = (idx == globalIndex)
        }
        centerSelectedCell(animated: animate)
    }

    /// Returns whether we should animate the next selection change.
    /// Returns false if less than 150 ms has passed since the last
    /// selection — arrow-key repeat rate is ~10 Hz so back-to-back
    /// animated centerings would queue up and stutter.
    private func shouldAnimateSelection() -> Bool {
        let now = CACurrentMediaTime()
        return (now - lastSelectionAt) >= 0.15
    }

    /// Fix C — replace `scrollToVisible` with explicit centering.
    /// `scrollToVisible` just guarantees presence in the visible rect;
    /// with variable-width cells the selected cell can end up pinned
    /// to either edge. We want it mid-strip so the user has symmetric
    /// preview of neighbors.
    private func centerSelectedCell(animated: Bool) {
        guard let selectedCell = cellsByIndex[currentGlobalIndex] else { return }
        // Force pending layout so the cell has final frame — otherwise
        // on first nav the stack's arranged subviews still have .zero
        // frames and we'd center on nothing.
        layoutSubtreeIfNeeded()

        guard let documentView = scrollView.documentView else { return }
        let cellFrameInDoc = selectedCell.convert(selectedCell.bounds, to: documentView)
        let visibleWidth = scrollView.contentView.bounds.width
        let documentWidth = documentView.bounds.width

        // Centered origin for the scrollview content.
        let targetX = cellFrameInDoc.midX - visibleWidth / 2.0
        // Clamp to valid scroll range.
        let maxX = max(0, documentWidth - visibleWidth)
        let clampedX = min(maxX, max(0, targetX))
        let targetOrigin = CGPoint(x: clampedX, y: scrollView.contentView.bounds.origin.y)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(targetOrigin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Resolve the backing scale for thumbnail pixel sizing. Prefer the
    /// owning window (cell's actual target screen); fall back to main
    /// screen; fall back to 2.0 for offscreen unit-test construction.
    private func backingScaleFactorForRequests() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: - Scroll-wheel scrubbing

    /// Fix B — split-axis scroll semantics.
    /// Vertical delta scrubs (discrete step per `cellSize + spacing`).
    /// Horizontal delta passes to `super` so NSScrollView handles pan
    /// with its native elasticity/momentum — feels like a native
    /// horizontal scroll.
    ///
    /// Mouse-wheel behaviour: classic wheels set
    /// `hasPreciseScrollingDeltas = false`; each notch is "one image"
    /// regardless of accumulator state, matching user expectation.
    /// Trackpads are precise — they feed the accumulator pixel-for-pixel.
    ///
    /// Momentum-phase events are ignored for scrub: inertial coast
    /// shouldn't keep advancing selection after the user has let go.
    fileprivate func handleScrollWheel(_ event: NSEvent, fallbackToSuper: () -> Void) {
        // Gesture end / cancel / momentum end — always reset the
        // accumulator so the next gesture starts clean.
        if event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) {
            scrollAccumulator = 0
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // Horizontal-dominant → native pan via NSScrollView.
        if abs(dx) > abs(dy) {
            fallbackToSuper()
            return
        }

        // Vertical-dominant → scrub. Mouse-wheel notches (non-precise
        // deltas) are one-image-per-event — bypass the accumulator.
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: each event = one scrub step. Ignore magnitude,
            // just use direction. This is the behavioral split flagged in
            // Precise devices accumulate, non-precise don't.
            if dy > 0 {
                onScrollScrub?(+1)
            } else if dy < 0 {
                onScrollScrub?(-1)
            }
            return
        }

        // Trackpads only from here. Skip inertial momentum coast — we
        // only want user-intent deltas driving the accumulator.
        let inMomentum = !event.momentumPhase.isEmpty
            && !event.momentumPhase.contains(.ended)
        guard !inMomentum else { return }

        scrollAccumulator += dy
        let step = cellSize + spacing
        while abs(scrollAccumulator) >= step {
            if scrollAccumulator > 0 {
                scrollAccumulator -= step
                onScrollScrub?(+1)
            } else {
                scrollAccumulator += step
                onScrollScrub?(-1)
            }
        }
    }

    /// Accumulates scroll-wheel pixels between `scrollWheel` events so we
    /// advance one thumb per `cellSize + spacing` pts. Precise trackpad
    /// deltas feed in directly; mouse-wheel notches bypass this entirely
    /// (see `handleScrollWheel`).
    private var scrollAccumulator: CGFloat = 0

    // MARK: - Hover (spec 24 §2)
    //
    // One tracking area for the whole strip. `mouseMoved` hit-tests the
    // cells; the cell under the pointer (not the selected one) shows the
    // ring and the veil. Only one cell is hovered at a time.

    private var hoverTracking: NSTrackingArea?
    /// The cell under the pointer, by global index.
    private(set) var hoveredGlobalIndex: Int?
    /// The pointer in window coordinates while it is inside the strip.
    private var hoverWindowPoint: NSPoint?
    private let scrollObservers = StripObserverBag()
    private var windowObservers = StripObserverBag()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
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
        hoverWindowPoint = point
        applyHover(at: point)
    }

    /// The pointer left, a drag started, the strip hid or the window lost key.
    func clearHover() {
        hoverWindowPoint = nil
        setHovered(index: nil)
    }

    /// The cells moved under a still pointer (scroll, new neighbours):
    /// hit-test again.
    func refreshHover() {
        if let point = hoverWindowPoint { applyHover(at: point) } else { setHovered(index: nil) }
    }

    private func applyHover(at point: NSPoint) {
        guard !isHidden, scrollView.frame.contains(convert(point, from: nil)) else {
            setHovered(index: nil)
            return
        }
        // The cell is found by its column: the strip's top and bottom
        // padding, the gap between two cells and the side padding all belong
        // to the nearest cell, so the hover shows on the very first pointer
        // move into the strip, not only once the pointer is exactly on a cell.
        let inStack = stackView.convert(point, from: nil)
        setHovered(index: nearestCellIndex(atStackX: inStack.x))
    }

    /// The cell whose column is closest to `x` (stack coordinates); a point
    /// inside a cell or its half gap is at distance 0.
    private func nearestCellIndex(atStackX x: CGFloat) -> Int? {
        let slack = stackView.spacing / 2
        var best: (index: Int, distance: CGFloat)?
        for (index, cell) in cellsByIndex {
            let frame = cell.frame
            let distance = max(frame.minX - slack - x, x - (frame.maxX + slack), 0)
            if best == nil || distance < best!.distance
                || (distance == best!.distance && index < best!.index) {
                best = (index, distance)
            }
        }
        // Only the strip's own padding counts, not empty room past the
        // last cell (a short folder).
        guard let best, best.distance <= stackView.edgeInsets.left else { return nil }
        return best.index
    }

    private func setHovered(index: Int?) {
        let valid = index.flatMap { cellsByIndex[$0] != nil ? $0 : nil }
        guard valid != hoveredGlobalIndex else { return }
        if let old = hoveredGlobalIndex { cellsByIndex[old]?.setHovered(false) }
        hoveredGlobalIndex = valid
        if let new = valid { cellsByIndex[new]?.setHovered(true) }
    }

    private func installHoverObservers() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservers.add(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        })
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

    override func viewDidHide() {
        super.viewDidHide()
        clearHover()
    }

    /// Test seams.
    internal var hoveredGlobalIndexForTesting: Int? { hoveredGlobalIndex }
    internal func hoverLookForTesting(_ cell: NSView)
        -> (ringWidth: CGFloat, ringColor: CGColor?, ringOpacity: Float, overlayAlpha: CGFloat)? {
        (cell as? ThumbCell)?.hoverLookForTesting
    }
    /// The centre of the cell for `globalIndex`, in window coordinates.
    internal func cellCenterInWindowForTesting(_ globalIndex: Int) -> NSPoint? {
        guard let cell = cellsByIndex[globalIndex] else { return nil }
        return cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
    }
    internal func hoverFadeForTesting(_ cell: NSView) -> CAAnimation? { (cell as? ThumbCell)?.hoverFadeForTesting }
    /// A right-click on a cell without the pop-up: selects the cell, returns the menu.
    internal func rightClickMenuForTesting(_ globalIndex: Int) -> NSMenu? {
        cellsByIndex[globalIndex]?.menuAfterSelectingCell()
    }
    internal func cellToolTipForTesting(_ cell: NSView) -> String? { cell.toolTip }
    /// Scrolls the strip sideways by `dx` points (clip-view bounds change).
    internal func scrollForTesting(by dx: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x + dx, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
    internal func dragBeganOnCellForTesting(_ globalIndex: Int) { cellsByIndex[globalIndex]?.onDragBegan?() }

    // MARK: - Test seams

    /// Test seam — returns the ordered list of global indices currently
    /// in the strip.
    internal func globalIndicesForTesting() -> [Int] {
        // Order by stack position so tests see the rendered order,
        // not dictionary enumeration order.
        stackView.arrangedSubviews.compactMap { ($0 as? ThumbCell)?.globalIndex }
    }

    /// Test seam — returns the `ObjectIdentifier` of every surviving
    /// cell, in stack order. Lets neighbor-shift tests assert that a
    /// window shift recycles the surviving cells (identity preserved)
    /// rather than tearing down and rebuilding the whole strip.
    internal var cellIdentitiesForTesting: [ObjectIdentifier] {
        stackView.arrangedSubviews.compactMap { ($0 as? ThumbCell).map(ObjectIdentifier.init) }
    }

    /// Test seam — returns the current scroll accumulator (used by tests
    /// that want to verify sub-threshold deltas don't emit). Reset any
    /// time `onScrollScrub` fires via the internal threshold math.
    internal var scrollAccumulatorForTesting: CGFloat { scrollAccumulator }

    /// Test seam — primes the scroll accumulator so unit tests can
    /// exercise the cross-threshold path without fabricating NSEvents.
    /// Invokes `onScrollScrub` for each whole step crossed. Vertical-only
    /// by design — the accumulator is only used for precise vertical
    /// deltas, which is the scrub path.
    internal func primeScrollAccumulatorForTesting(_ delta: CGFloat) {
        scrollAccumulator += delta
        let step = cellSize + spacing
        while abs(scrollAccumulator) >= step {
            if scrollAccumulator > 0 {
                scrollAccumulator -= step
                onScrollScrub?(+1)
            } else {
                scrollAccumulator += step
                onScrollScrub?(-1)
            }
        }
    }

    /// Test seam — simulate a gesture-end / momentum-end event arriving
    /// on the filmstrip. Resets the accumulator exactly like
    /// `handleScrollWheel` would for an `event.phase.contains(.ended)`.
    internal func simulateScrollGestureEndForTesting() {
        scrollAccumulator = 0
    }

    /// Test seam — exposes the current scroll origin so rapid-selection
    /// tests can assert the animation path was bypassed (no animation
    /// key installed on the layer).
    internal var scrollOriginForTesting: CGPoint {
        scrollView.contentView.bounds.origin
    }

    /// Test seam — seeds the `lastSelectionAt` timestamp so tests can
    /// exercise both the animated and the snap-center paths without
    /// racing the real clock.
    internal func setLastSelectionTimestampForTesting(_ t: CFTimeInterval) {
        lastSelectionAt = t
    }

    /// Test seam — inject a pre-built cell with a specific aspect ratio
    /// so geometry-only tests can exercise the width-clamp math without
    /// going through `requestThumbnail`.
    internal func injectCellForTesting(globalIndex: Int, aspect: CGFloat) -> NSView {
        let cell = ThumbCell(globalIndex: globalIndex, source: SyntheticPlaceholderSource(id: "t\(globalIndex)"))
        cell.setCellSize(cellSize)
        cell.overrideAspectForTesting(aspect)
        cell.onDragBegan = { [weak self] in self?.clearHover() }
        cellsByIndex[globalIndex] = cell
        stackView.addArrangedSubview(cell)
        return cell
    }

    /// Test seam — selects an injected cell, draws it, and returns its
    /// selection ring width (3 pt under Increase Contrast).
    internal func selectionRingWidthForTesting(selecting cell: NSView) -> CGFloat {
        guard let cell = cell as? ThumbCell else { return 0 }
        cell.isSelected = true
        cell.updateLayer()
        return cell.highlightWidthForTesting
    }

    /// Test seam — returns the current cell size in pts.
    internal var cellSizeForTesting: CGFloat { cellSize }

    /// Test seam — returns the current mode.
    internal var modeForTesting: Mode { mode }

    /// Test seam — returns the aspect cache populated via the
    /// `ThumbCell.aspectCacheHook` (cells
    /// re-entering the neighbor window reuse their cached aspect).
    internal var recentAspectsForTesting: [Int: CGFloat] { recentAspects }

    /// Test seam — exposes the pin corner overlay (for frame checks).
    internal var pinOverlayForTesting: PinCornerOverlay { pinOverlay }

    /// Test seam — exposes the content view (scroll view) for overlap
    /// assertions. The scroll view fills the full
    /// panel (no reserved strip), so overlap checks run against
    /// `pinOverlayForTesting.frame`.
    internal var contentViewForTesting: NSView { scrollView }

    /// Test seam — inject a mock thumbnail pipeline so unit tests can
    /// observe the `maxPixelSize` value threaded into a cell's request
    /// without actually hitting disk or the real `ThumbnailCache`.
    internal var thumbnailPixelSizeSink: ((Int) -> Void)? {
        get { ThumbCell.testingSink }
        set { ThumbCell.testingSink = newValue }
    }

    /// Test seam — observe aspect updates applied to any cell. Primarily
    /// used by `FilmstripThumbAspectFromImageTests` to assert that the
    /// thumbnail-load path (not the separate header probe) is the one
    /// that settles a cell's final aspect ratio.
    internal var cellAspectAppliedSink: ((Int, CGFloat) -> Void)? {
        get { ThumbCell.aspectAppliedSink }
        set { ThumbCell.aspectAppliedSink = newValue }
    }

    /// Test seam — simulate a thumbnail arriving for a specific cell,
    /// which exercises the aspect-from-image path without a real decode.
    internal func simulateThumbnailDeliveredForTesting(globalIndex: Int, pixelWidth: Int, pixelHeight: Int) {
        cellsByIndex[globalIndex]?.applyAspectFromDeliveredThumbForTesting(width: pixelWidth, height: pixelHeight)
    }

    /// Test seam — invoke the private `ThumbCell.ioThumbnail` fallback
    /// path directly. Used to assert the oversized-request clamp at the
    /// filmstrip's cache-miss entry point (sibling of the clamp
    /// inside `FileImageSource.loadCGImage`). `ThumbCell` is fileprivate
    /// so tests can't reach it without this thin forward.
    nonisolated internal static func ioThumbnailForTesting(url: URL, maxPixelSize: Int) -> CGImage? {
        ThumbCell.ioThumbnail(url: url, maxPixelSize: maxPixelSize)
    }
}

/// NSScrollView subclass that forwards scrollWheel to the filmstrip's
/// split-axis handler. The handler decides whether to fall through to
/// `super.scrollWheel(with:)` (horizontal pan) or consume the event
/// (vertical scrub).
@MainActor
private final class FilmstripScrollView: NSScrollView {
    weak var filmstrip: FilmstripView?

    override func scrollWheel(with event: NSEvent) {
        guard let filmstrip else {
            super.scrollWheel(with: event)
            return
        }
        // `super.scrollWheel` is not usable from inside a closure that
        // captures self explicitly; route through a small instance
        // method so the closure can call it.
        filmstrip.handleScrollWheel(event) { [weak self] in
            self?.forwardScrollWheelToSuper(event)
        }
    }

    private func forwardScrollWheelToSuper(_ event: NSEvent) {
        super.scrollWheel(with: event)
    }
}

// MARK: - ThumbCell

@MainActor
private final class ThumbCell: NSView, NSDraggingSource {
    let globalIndex: Int
    let source: any ImageSource

    var onClick: ((Int) -> Void)?
    /// The pasteboard item a drag out carries.
    var dragItemProvider: ((Int) -> NSPasteboardItem?)?
    private var mouseDownPoint: NSPoint?

    private let imageView = NSImageView()
    /// Shown when the file can't be previewed (spec 25 §2.2).
    private let brokenView = NSImageView()
    private(set) var isUnreadable = false
    private let highlight = NSView()
    /// The running thumbnail request; cancelled when the cell leaves the
    /// strip, so a queued decode for a photo nobody sees any more is dropped.
    private var thumbnailTask: Task<Void, Never>?

    func cancelThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }
    /// Stars bottom-left (8 pt), flag top-left (9 pt), 3 pt inset.
    private let starsLabel = NSTextField(labelWithString: "")
    private let flagView = NSImageView()
    private(set) var shownMarks: (rating: Int, flagged: Bool) = (0, false)

    func setMarks(rating: Int, flagged: Bool) {
        guard shownMarks.rating != rating || shownMarks.flagged != flagged else { return }
        shownMarks = (rating, flagged)
        starsLabel.stringValue = Badges.stars(rating)
        starsLabel.isHidden = rating <= 0
        flagView.isHidden = !flagged
    }

    var flagDrawnForTesting: Bool {
        !flagView.isHidden && flagView.image != nil && flagView.frame.width > 0 && flagView.superview === self
    }
    var starsDrawnForTesting: Bool { !starsLabel.isHidden && !starsLabel.stringValue.isEmpty }

    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    /// Current cell height in pts. Width is derived as `height × aspect`
    /// clamped to `[0.5×, 1.6×]`.
    private var heightPt: CGFloat = 72
    /// Aspect ratio (width / height). Defaults to 1.0 (square) until
    /// resolved; when the async resolve lands, the width constraint is
    /// updated. 1:1 is also the fallback for images whose header we can't
    /// read. Once a thumbnail arrives, the cell overrides
    /// this with the delivered image's own pixel ratio — eliminating the
    /// visible delay for portrait detection that the header-only path had
    /// when the ThumbnailCache was fast but the header probe was slow.
    private var aspect: CGFloat = 1.0
    /// Once true, the aspect was settled from a delivered thumbnail —
    /// subsequent header-probe results are ignored. Guarantees we always
    /// prefer the authoritative decoded value over the pre-decode probe.
    private var aspectSettledFromThumb: Bool = false

    /// Test hook — when set, every `requestThumbnail` pushes its
    /// `maxPixelSize` through this sink instead of calling the real
    /// cache. See `FilmstripView.thumbnailPixelSizeSink`.
    static var testingSink: ((Int) -> Void)?

    /// Test hook — fires every time `applyAspect` changes a cell's
    /// aspect. Used to verify that the aspect derives from the
    /// delivered thumbnail, not a separate header read.
    static var aspectAppliedSink: ((Int, CGFloat) -> Void)?

    /// Internal hook — the owning `FilmstripView` installs this to
    /// populate its `recentAspects` cache so cells that leave + re-enter
    /// the neighbor window don't flash 1:1 while the thumbnail redecodes
    static var aspectCacheHook: ((Int, CGFloat) -> Void)?

    /// Selection ring: 2 pt, 3 pt under Increase Contrast.
    static var selectionRingWidth: CGFloat { ShrikeTokens.increaseContrast ? 3 : 2 }

    var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            highlight.layer?.borderWidth = isSelected ? Self.selectionRingWidth : 0
            needsDisplay = true
            // The selected look wins over the hover look.
            applyHover(animated: false)
        }
    }

    // MARK: Hover (spec 24 §2)

    /// A white 10 % veil on the photo, below the stars and the flag.
    private let hoverOverlay = StripPassThroughView()
    /// The hover ring, inside the cell edge.
    private let hoverRing = StripPassThroughView()
    /// The pointer is over this cell. The strip owns the tracking.
    private(set) var isHovered = false
    /// Fired when this cell starts a drag out: the strip clears the hover.
    var onDragBegan: (() -> Void)?

    func setHovered(_ on: Bool, animated: Bool = true) {
        guard on != isHovered else { return }
        isHovered = on
        applyHover(animated: animated)
    }

    /// Hover shows only on a cell that is not selected.
    private var showsHover: Bool { isHovered && !isSelected }

    private func applyHover(animated: Bool) {
        guard let ring = hoverRing.layer, let veil = hoverOverlay.layer else { return }
        StripHoverLook.fade(ring, visible: showsHover, animated: animated)
        StripHoverLook.fade(veil, visible: showsHover, animated: animated)
    }

    /// Test seam: what the hover draws now (target state).
    var hoverLookForTesting: (ringWidth: CGFloat, ringColor: CGColor?, ringOpacity: Float, overlayAlpha: CGFloat) {
        let veil = hoverOverlay.layer
        let veilAlpha = (veil?.opacity ?? 0) > 0 ? (veil?.backgroundColor?.alpha ?? 0) : 0
        return (hoverRing.layer?.borderWidth ?? 0, hoverRing.layer?.borderColor, hoverRing.layer?.opacity ?? 0,
                veilAlpha)
    }

    /// Test seam: the fade running on the ring, if any.
    var hoverFadeForTesting: CAAnimation? { hoverRing.layer?.animation(forKey: "shrike.stripHover") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private var colorObserver: LiveColorObserver?

    override var wantsUpdateLayer: Bool { true }

    /// Colours resolve at draw time, so an accent or
    /// Light/Dark change shows at once.
    override func updateLayer() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = ShrikeTokens.surfaceSunken.resolvedCGColor(for: appearance)
        highlight.layer?.borderColor = isSelected
            ? ShrikeAccent.mark.resolvedCGColor(for: appearance) : nil
        highlight.layer?.borderWidth = isSelected ? Self.selectionRingWidth : 0
        // Hover: ring colour and width resolve here (Increase Contrast,
        // appearance); the veil colour is plain white.
        hoverRing.layer?.borderColor = StripHoverLook.ringColor(for: appearance)
        hoverRing.layer?.borderWidth = StripHoverLook.ringWidth
        hoverOverlay.layer?.backgroundColor = StripHoverLook.overlayColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Test seam: the ring colour as drawn.
    var highlightColorForTesting: CGColor? { highlight.layer?.borderColor }
    /// Test seam: the ring width as drawn.
    var highlightWidthForTesting: CGFloat { highlight.layer?.borderWidth ?? 0 }

    init(globalIndex: Int, source: any ImageSource) {
        self.globalIndex = globalIndex
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 72))

        wantsLayer = true
        colorObserver = LiveColorObserver(view: self)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        brokenView.translatesAutoresizingMaskIntoConstraints = false
        brokenView.contentTintColor = Badges.brokenFileTint
        brokenView.isHidden = true
        addSubview(brokenView)
        NSLayoutConstraint.activate([
            brokenView.centerXAnchor.constraint(equalTo: centerXAnchor),
            brokenView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Hover veil: above the photo, below the stars and the flag.
        hoverOverlay.wantsLayer = true
        hoverOverlay.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.layer?.cornerRadius = StripHoverLook.cornerRadius
        hoverOverlay.layer?.masksToBounds = true
        hoverOverlay.layer?.backgroundColor = StripHoverLook.overlayColor
        hoverOverlay.layer?.opacity = 0
        addSubview(hoverOverlay)

        highlight.wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.layer?.cornerRadius = 6
        addSubview(highlight)

        hoverRing.wantsLayer = true
        hoverRing.translatesAutoresizingMaskIntoConstraints = false
        hoverRing.layer?.cornerRadius = StripHoverLook.cornerRadius
        hoverRing.layer?.borderWidth = StripHoverLook.ringWidth
        hoverRing.layer?.opacity = 0
        addSubview(hoverRing)
        if let url = (source as? FileImageSource)?.url { toolTip = url.lastPathComponent }

        starsLabel.translatesAutoresizingMaskIntoConstraints = false
        starsLabel.font = .systemFont(ofSize: 8)
        starsLabel.textColor = Badges.ratingColor
        starsLabel.isHidden = true
        Badges.applyThumbnailShadow(to: starsLabel)
        addSubview(starsLabel)
        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.image = Badges.symbol("flag.fill", pointSize: 9, color: Badges.flagColor)
        flagView.isHidden = true
        Badges.applyThumbnailShadow(to: flagView)
        addSubview(flagView)
        NSLayoutConstraint.activate([
            starsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            starsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            flagView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            flagView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
        ])

        widthConstraint = widthAnchor.constraint(equalToConstant: 72)
        heightConstraint = heightAnchor.constraint(equalToConstant: 72)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // P3: the ring sits outside the thumbnail.
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            hoverOverlay.topAnchor.constraint(equalTo: topAnchor),
            hoverOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The hover ring sits inside the cell edge.
            hoverRing.topAnchor.constraint(equalTo: topAnchor),
            hoverRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverRing.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Resolve aspect from the image header (header-only properties
        // read is 2-4 ms) so the cell can size itself BEFORE the
        // thumbnail finishes decoding — eliminates the "all squares"
        // flash on first folder open. Once the thumb arrives, its own
        // dimensions take over (see issue #9 fix in `requestThumbnail`).
        resolveAspect()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        onClick?(globalIndex)
    }

    /// Right-click: the cell becomes the displayed photo first (the menu acts
    /// on the displayed photo), then the viewer menu opens (spec 25 §12.2).
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuAfterSelectingCell() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// Makes this cell the displayed photo, then gives the menu to open.
    func menuAfterSelectingCell() -> NSMenu? {
        onClick?(globalIndex)
        return onContextMenu?()
    }

    /// The viewer's context menu; set by the strip's owner.
    var onContextMenu: (() -> NSMenu?)?

    /// A drag of 4 pt or more starts a drag out.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4,
              let item = dragItemProvider?(globalIndex) else { return }
        mouseDownPoint = nil
        onDragBegan?()
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: imageView.image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        BrowserDropRules.sourceMask(for: context)
    }

    /// Set the cell height in pts. Width is recomputed from the current
    /// aspect, clamped to `[height × 0.5, height × 1.6]`. Matches Apple
    /// Photos / Lightroom filmstrip convention (portrait thumbs narrow,
    /// landscape thumbs wider, inside bounded min/max).
    func setCellSize(_ pt: CGFloat) {
        heightPt = pt
        heightConstraint.constant = pt
        updateWidthConstraint()
    }

    fileprivate func overrideAspectForTesting(_ a: CGFloat) {
        aspect = max(0.01, a)
        updateWidthConstraint()
    }

    fileprivate func applyAspectFromDeliveredThumbForTesting(width: Int, height: Int) {
        applyAspectFromThumb(width: width, height: height)
    }

    private func updateWidthConstraint() {
        let rawWidth = heightPt * aspect
        let minWidth = heightPt * 0.5
        let maxWidth = heightPt * 1.6
        widthConstraint.constant = min(maxWidth, max(minWidth, rawWidth))
    }

    /// Resolve the image's pixel aspect ratio from its header properties
    /// (no pixel decode). Fast path: for `FileImageSource` we go through
    /// ImageIO directly so we don't spin up a decode task. For other
    /// source types we fall back to `loadProperties()`.
    private func resolveAspect() {
        if let file = source as? FileImageSource {
            let url = file.url
            Task.detached(priority: .userInitiated) { [weak self] in
                let (w, h) = Self.ioAspect(url: url)
                guard w > 0, h > 0 else { return }
                let a = CGFloat(w) / CGFloat(h)
                await MainActor.run { self?.applyAspectFromHeader(a) }
            }
            return
        }
        // Generic path — use the source's own properties. Errors just
        // leave us at the 1:1 fallback.
        let src = source
        Task { [weak self] in
            guard let props = try? await src.loadProperties(),
                  props.pixelWidth > 0, props.pixelHeight > 0 else { return }
            let ox = normalisedOrientation(props.orientation)
            // Orientations 5-8 swap width/height in the displayed frame.
            let swap = (5...8).contains(ox)
            let w = swap ? props.pixelHeight : props.pixelWidth
            let h = swap ? props.pixelWidth : props.pixelHeight
            let a = CGFloat(w) / CGFloat(h)
            await MainActor.run { self?.applyAspectFromHeader(a) }
        }
    }

    /// Header-probe path — only applies aspect if the thumbnail hasn't
    /// already settled it. This is the "fast initial layout" hint that
    /// prevents a flash of squares while the decode spins up.
    private func applyAspectFromHeader(_ a: CGFloat) {
        guard !aspectSettledFromThumb else { return }
        guard a.isFinite, a > 0 else { return }
        aspect = a
        updateWidthConstraint()
        Self.aspectAppliedSink?(globalIndex, a)
        Self.aspectCacheHook?(globalIndex, a)
    }

    /// Thumbnail-delivery path — authoritative. Takes pixel dimensions
    /// from the decoded `CGImage` (which has already had EXIF orientation
    /// transforms applied by `kCGImageSourceCreateThumbnailWithTransform`)
    /// and settles the cell's aspect ratio. Subsequent header-probe
    /// results are ignored once this has run.
    var aspectForTesting: CGFloat { aspect }

    private func applyAspectFromThumb(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let a = CGFloat(width) / CGFloat(height)
        guard a.isFinite, a > 0 else { return }
        aspect = a
        aspectSettledFromThumb = true
        updateWidthConstraint()
        Self.aspectAppliedSink?(globalIndex, a)
        Self.aspectCacheHook?(globalIndex, a)
    }

    func requestThumbnail(
        services: ShrikeServices,
        fallbackFor source: any ImageSource,
        maxPixelSize: Int
    ) {
        // Test hook — short-circuit the real cache so unit tests can
        // observe the requested pixel size.
        if let sink = Self.testingSink {
            sink(maxPixelSize)
            return
        }

        let cache = services.thumbnailCache
        let src = source
        let targetSize = maxPixelSize
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            if let thumb = try? await cache.thumbnail(for: src, maxPixelSize: targetSize) {
                let w = thumb.width
                let h = thumb.height
                await MainActor.run {
                    // Issue #9: derive cell aspect from the delivered
                    // thumbnail's own dimensions — no second header read
                    // race, and the CGImage has already had any EXIF
                    // orientation transform baked in by
                    // `kCGImageSourceCreateThumbnailWithTransform`.
                    self?.applyAspectFromThumb(width: w, height: h)
                    // Unpin the NSImage representation size so Retina
                    // renders at the CGImage's native resolution.
                    self?.imageView.image = NSImage(cgImage: thumb, size: .zero)
                }
                return
            }
            // Cancelled (the cell left the strip): no second, uncached read.
            if Task.isCancelled { return }
            if let file = src as? FileImageSource,
               let thumb = Self.ioThumbnail(url: file.url, maxPixelSize: targetSize) {
                let w = thumb.width
                let h = thumb.height
                await MainActor.run {
                    self?.applyAspectFromThumb(width: w, height: h)
                    self?.imageView.image = NSImage(cgImage: thumb, size: .zero)
                }
            } else if !Task.isCancelled {
                await MainActor.run { self?.showUnreadable() }
            }
        }
    }

    /// The thumbnail can't be made: the same glyph as the Browser cell
    /// (no text; the strip cell is small) and a tooltip that says so.
    func showUnreadable() {
        isUnreadable = true
        brokenView.image = Badges.brokenFileGlyph(pointSize: min(20, heightPt * 0.3))
        brokenView.isHidden = false
        let name = (source as? FileImageSource)?.url.lastPathComponent
        if let name { toolTip = "\(name) — can't preview" }
    }

    /// VoiceOver: name, stars, flag, can't preview (spec 25 §7.2), like the grid cell.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    /// One element per cell: the picture and glyph inside are not read on their own.
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityLabel() -> String? {
        let name = (source as? FileImageSource)?.url.lastPathComponent ?? ""
        return CellAccessibility.label(name: name, rating: shownMarks.rating, flagged: shownMarks.flagged,
                                       isPair: false, failed: isUnreadable)
    }

    var brokenGlyphShownForTesting: Bool { !brokenView.isHidden }

    nonisolated static func ioThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Clamp the thumbnail request to the source's longer edge so
        // ImageIO never emits `createThumbnailAtIndex: N is larger than
        // image-dimension: WxH` on the ASL error channel. The sibling
        // fix closed this hole inside
        // `FileImageSource.loadCGImage`, but this filmstrip fallback
        // path opens its own `CGImageSource` and passed `maxPixelSize`
        // through unclamped — so the oversized-request warning plus
        // the downstream `IOSurface creation failed: e00002c2` burst
        // were still firing on ThumbnailCache-miss. Match the
        // FileImageSource pattern: one header read (~2-4 ms per
        // each, reused from the same `src`) gives us
        // the dims cheaply. If the header is unreadable (rare, corrupt
        // container), fall back to the raw request — decoding still
        // succeeds, the ImageIO warning is cosmetic.
        let clamped: Int = {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0
            else { return maxPixelSize }
            return max(1, min(maxPixelSize, max(w, h)))
        }()

        // Full flag combination:
        // `ShouldCacheImmediately = true` + `ShouldCache = false`
        // is required for the Shrike decode model (we own our own LRU;
        // ImageIO's internal cache costs 10-40× without helping us).
        // The two cache keys were historically omitted from this
        // fallback path, leaving the filmstrip's non-cache route slower
        // than the primary `ThumbnailCache` path.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clamped,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Header-only aspect probe. Uses `CGImageSourceCopyPropertiesAtIndex`
    /// with `kCGImageSourceShouldCache = false` so we pay only the file
    /// header read (2-4 ms per file).
    /// Returns `(width, height)` in pixels as reported by the container.
    nonisolated static func ioAspect(url: URL) -> (Int, Int) {
        let sourceOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else {
            return (0, 0)
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swap = (5...8).contains(orientation)
        return swap ? (h, w) : (w, h)
    }
}

/// Orientation-swap helper — EXIF orientations 5/6/7/8 require swapping
/// width/height when rendering.
private nonisolated func normalisedOrientation(_ o: CGImagePropertyOrientation) -> UInt32 {
    UInt32(o.rawValue)
}

/// Placeholder source used by `injectCellForTesting` — produces no pixels
/// and never resolves properties (aspect stays at the injected override).
private struct SyntheticPlaceholderSource: ImageSource {
    let id: String
    var displayName: String { id }
    var fileSize: Int64? { nil }
    var mtime: Date? { nil }

    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        throw ImageSourceError.unsupported
    }

    func loadProperties() async throws -> ImageProperties {
        throw ImageSourceError.unsupported
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - PinCornerOverlayDelegate

extension FilmstripView: PinCornerOverlayDelegate {
    func pinCornerOverlayDidToggle(_ overlay: PinCornerOverlay) {
        // Delegate to the enclosing controller's toggle callback — it
        // owns authoritative pin state (pref + pinnedPanels set). Our
        // `pinned` flag will be updated via `setPinned(_:)` on the next
        // state sync, so we don't pre-emptively flip it here.
        onTogglePin?()
    }
}

/// The strip's row of cells. Tells the strip after every layout pass, so the
/// hover follows cells that moved under a still pointer (a thumbnail arrived
/// and changed a cell's width).
@MainActor
private final class StripStackView: NSStackView {
    var onLaidOut: (() -> Void)?
    override func layout() {
        super.layout()
        onLaidOut?()
    }
}

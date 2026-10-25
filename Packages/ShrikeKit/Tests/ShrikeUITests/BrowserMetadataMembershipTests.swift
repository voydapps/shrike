import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserMetadataMembershipTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var services: ShrikeServices!
    private var browsers: [BrowserWindowController] = []
    private var viewers: [ViewerWindow] = []
    private var savedReview = false, savedAdvance = false
    private var savedSort = "", savedAscending = true, savedPresents = true
    private var savedMotion: Bool?
    private var heldHydration: CheckedContinuation<Void, Never>?
    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-membership-\(UUID())")
        folder = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        savedReview = Prefs.reviewControlsVisible; savedAdvance = Prefs.advanceAfterRating
        savedSort = Prefs.browserSortKey; savedAscending = Prefs.browserSortAscending
        savedMotion = ReduceMotion.overrideForTesting; ReduceMotion.overrideForTesting = true
        savedPresents = CompareWindow.presentsWindows; CompareWindow.presentsWindows = false
        Prefs.browserSortKey = "name"; Prefs.browserSortAscending = true
    }
    override func tearDown() async throws {
        CullingUndo.beforeWriteForTesting = nil
        heldHydration?.resume(); heldHydration = nil
        await CullingUndo.waitForPendingWrites()
        CompareWindow.current?.close()
        viewers.forEach { $0.close() }; browsers.forEach { $0.close() }
        viewers = []; browsers = []
        await services.thumbnailCache.waitForPendingDiskWrites(); await services.thumbnailCache.evictMemory()
        Prefs.reviewControlsVisible = savedReview; Prefs.advanceAfterRating = savedAdvance
        Prefs.browserSortKey = savedSort; Prefs.browserSortAscending = savedAscending
        ReduceMotion.overrideForTesting = savedMotion; CompareWindow.presentsWindows = savedPresents
        try? FileManager.default.removeItem(at: root)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Controlled Browser/Viewer work must finish")
    }
    private func photos() throws -> [URL] {
        try ["a-bright.jpg", "b-dark.jpg", "c-bright.jpg"].map { name in
            let url = folder.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 400, height: 300), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
        }
    }
    private func browser(holdHydration: Bool = false) async throws -> BrowserWindowController {
        let browser = BrowserWindowController(services: services, initialFolder: folder)
        browsers.append(browser)
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        if holdHydration {
            browser.hydrationGateForTesting = { [weak self] in
                await withCheckedContinuation { self?.heldHydration = $0 }
            }
        }
        if !holdHydration { await browser.listingTask?.value }
        try await until { holdHydration ? self.heldHydration != nil : hydrated }
        browser.window?.setContentSize(NSSize(width: 1000, height: 700)); browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }
    private func visible(_ browser: BrowserWindowController) -> [URL] { browser.contentController.visibleItems.map(\.url) }
    private func assertEmptySelection(_ browser: BrowserWindowController, line: UInt = #line) {
        XCTAssertTrue(browser.contentController.selectedItems.isEmpty, line: line)
        XCTAssertEqual(browser.inspectorStateForTesting.count, 0, line: line)
        XCTAssertEqual(browser.statusTextForTesting, BrowserBottomBar.statusText([]), line: line)
    }
    private func persistedKeepers() async throws -> [URL] {
        let urls = try photos()
        for (url, rating) in zip(urls, [5, 4, 2]) { try await services.metadataStore.setRating(rating, for: url) }
        return urls
    }

    private func holdNextReload(_ browser: BrowserWindowController) {
        browser.hydrationGateForTesting = { [weak self] in
            await withCheckedContinuation { self?.heldHydration = $0 }
        }
        browser.reloadCurrentFolder()
    }

    func testRatedFilteredReloadKeepsSurvivingSelectionAndAnchorDuringHydration() async throws {
        let urls = try await persistedKeepers()
        for mode in [BrowserViewMode.grid, .list, .filmstrip] {
            let browser = try await browser(), content = browser.contentController
            content.filter = BrowserFilter(minimumRating: 4)
            content.setMode(.grid)
            let grid = content.collectionViewForTesting
            grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
            grid.noteClick(on: IndexPath(item: 1, section: 0), command: false)
            grid.extendSelection(to: IndexPath(item: 0, section: 0))
            content.setMode(mode)
            XCTAssertEqual(content.selectionAnchorURL, urls[1])
            XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)))
            holdNextReload(browser)
            let reload = browser.listingTask
            try await until { self.heldHydration != nil }
            XCTAssertTrue(content.isHydratingMarks)
            XCTAssertEqual(visible(browser), Array(urls.prefix(2)), "Known marks keep surviving filtered items at first paint")
            XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)), "First paint must not discard a deliberate selection")
            XCTAssertEqual(content.selectionAnchorURL, urls[1])
            heldHydration?.resume(); heldHydration = nil
            await reload?.value
            XCTAssertEqual(visible(browser), Array(urls.prefix(2)))
            XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)))
            XCTAssertEqual(content.selectionAnchorURL, urls[1])
            XCTAssertEqual(content.filter, BrowserFilter(minimumRating: 4))
            XCTAssertEqual(browser.inspectorStateForTesting.count, 2)
            let scope = ContactSheetScope(allCount: content.visibleItems.count, folderName: "Photos", selectedCount: content.selectedItems.count)
            XCTAssertTrue(scope.defaultsToSelection)
            XCTAssertEqual(scope.selectedTitle, "2 selected photos")
            browser.hydrationGateForTesting = nil; browser.close()
        }
    }

    func testNewerChoiceOrExplicitDeselectDuringFilteredHydrationWins() async throws {
        let urls = try await persistedKeepers()
        for chooseOne in [true, false] {
            let browser = try await browser(), content = browser.contentController
            content.filter = BrowserFilter(minimumRating: 4)
            XCTAssertTrue(content.select(urls: Array(urls.prefix(2))))
            holdNextReload(browser); let reload = browser.listingTask
            try await until { self.heldHydration != nil }
            if chooseOne { XCTAssertTrue(content.select(url: urls[1])) }
            else { content.deselectAll() }
            heldHydration?.resume(); heldHydration = nil
            await reload?.value
            XCTAssertEqual(content.selectedItems.map(\.url), chooseOne ? [urls[1]] : [])
            XCTAssertEqual(visible(browser), Array(urls.prefix(2)))
            XCTAssertEqual(browser.inspectorStateForTesting.count, chooseOne ? 1 : 0)
            browser.hydrationGateForTesting = nil; browser.close()
        }
    }

    func testAuthoritativeRatingExclusionDropsOnlyThatSelectedKeeper() async throws {
        let urls = try await persistedKeepers(), browser = try await browser(), content = browser.contentController
        content.filter = BrowserFilter(minimumRating: 4)
        XCTAssertTrue(content.select(urls: Array(urls.prefix(2))))
        try await services.metadataStore.setRating(1, for: urls[1])
        holdNextReload(browser); let reload = browser.listingTask
        try await until { self.heldHydration != nil }
        XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)))
        heldHydration?.resume(); heldHydration = nil
        await reload?.value
        XCTAssertEqual(visible(browser), [urls[0]])
        XCTAssertEqual(content.selectedItems.map(\.url), [urls[0]])
        XCTAssertEqual(browser.inspectorStateForTesting.count, 1)
        XCTAssertEqual(content.allItems.first { $0.url == urls[1] }?.rating, 1)
        XCTAssertEqual(content.filter, BrowserFilter(minimumRating: 4))
    }

    func testFlagAndTagFilteredReloadsKeepKnownMarksAndSelections() async throws {
        let urls = try photos()
        try await services.metadataStore.setFlag(true, for: Array(urls.prefix(2)))
        for url in urls.prefix(2) { try FinderTags.write(url, tags: ["Keep"]) }
        for filter in [BrowserFilter(flaggedOnly: true), BrowserFilter(tags: ["Keep"])] {
            let browser = try await browser(), content = browser.contentController
            content.filter = filter
            XCTAssertEqual(visible(browser), Array(urls.prefix(2)))
            XCTAssertTrue(content.select(urls: Array(urls.prefix(2))))
            holdNextReload(browser); let reload = browser.listingTask
            try await until { self.heldHydration != nil }
            XCTAssertEqual(visible(browser), Array(urls.prefix(2)))
            XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)))
            heldHydration?.resume(); heldHydration = nil
            await reload?.value
            XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set(urls.prefix(2)))
            XCTAssertEqual(content.filter, filter)
            browser.hydrationGateForTesting = nil; browser.close()
        }
    }

    func testDeletedKeeperCannotReturnThroughKnownMarksOrLateHydration() async throws {
        let urls = try await persistedKeepers(), browser = try await browser(), content = browser.contentController
        content.filter = BrowserFilter(minimumRating: 4)
        XCTAssertTrue(content.select(urls: Array(urls.prefix(2))))
        browser.stopWatching()
        try FileManager.default.removeItem(at: urls[1])
        holdNextReload(browser); let reload = browser.listingTask
        try await until { self.heldHydration != nil }
        XCTAssertEqual(visible(browser), [urls[0]])
        XCTAssertEqual(content.selectedItems.map(\.url), [urls[0]])
        heldHydration?.resume(); heldHydration = nil
        await reload?.value
        XCTAssertEqual(content.allItems.map(\.url), [urls[0], urls[2]])
        XCTAssertEqual(visible(browser), [urls[0]])
        XCTAssertEqual(content.selectedItems.map(\.url), [urls[0]])
    }

    func testFilteredReloadCannotCarrySelectionAcrossNewFolderOrOldHydration() async throws {
        let urls = try await persistedKeepers(), browser = try await browser(), content = browser.contentController
        content.filter = BrowserFilter(minimumRating: 4)
        XCTAssertTrue(content.select(urls: Array(urls.prefix(2))))
        var first = true, landed = 0
        browser.onHydratedForTesting = { landed += 1 }
        browser.hydrationGateForTesting = { [weak self] in
            if first { first = false; await withCheckedContinuation { self?.heldHydration = $0 } }
        }
        browser.reloadCurrentFolder(); let old = browser.listingTask
        try await until { self.heldHydration != nil }
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = other.appendingPathComponent("target.jpg")
        try FileManager.default.copyItem(at: urls[0], to: target)
        try await services.metadataStore.setRating(5, for: target)
        browser.navigate(to: other); await browser.listingTask?.value
        XCTAssertEqual(visible(browser), [target])
        // Opening a mark-filtered folder has no selectable first-paint item.
        // The user's explicit B selection must beat the held old A request.
        XCTAssertTrue(content.select(url: target))
        XCTAssertEqual(content.selectedItems.map(\.url), [target])
        heldHydration?.resume(); heldHydration = nil
        await old?.value
        XCTAssertEqual(visible(browser), [target])
        XCTAssertEqual(content.selectedItems.map(\.url), [target])
        XCTAssertEqual(content.filter, BrowserFilter(minimumRating: 4))
        XCTAssertEqual(browser.currentFolder, other.standardizedFileURL)
        XCTAssertEqual(landed, 1, "Superseded hydration never publishes or restores old selection")
    }

    func testPairedReviewCommitUndoRedoUpdatesUnratedMembershipWithoutReplayingAdvance() async throws {
        let urls = try photos(), browser = try await browser()
        var filter = BrowserFilter(searchTerm: "bright"); filter.unratedOnly = true
        browser.contentController.filter = filter; browser.updateSubtitle()
        XCTAssertTrue(browser.contentController.select(url: urls[0]))
        Prefs.reviewControlsVisible = true; Prefs.advanceAfterRating = true
        let groups = browser.contentController.visibleItems.map(\.group)
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services); viewers.append(viewer)
        viewer.pairedBrowser = browser; browser.pairedViewer = viewer
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == urls[0] }
        viewer.windowUndoManager.groupsByEvent = false; viewer.windowUndoManager.beginUndoGrouping()
        viewer.rateDisplayed(4); viewer.windowUndoManager.endUndoGrouping()
        await CullingUndo.waitForPendingWrites()
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == urls[2] }
        XCTAssertEqual(visible(browser), [urls[2]]); assertEmptySelection(browser)
        viewer.windowUndoManager.undo(); await CullingUndo.waitForPendingWrites()
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == urls[0] }
        XCTAssertEqual(visible(browser), [urls[0], urls[2]])
        viewer.windowUndoManager.redo(); await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0], "Redo must not repeat automatic navigation")
        XCTAssertEqual(visible(browser), [urls[2]])
        XCTAssertEqual(browser.contentController.filter, filter)
        XCTAssertEqual(browser.window?.subtitle, WindowTitles.browserSubtitle(visible: 1, total: 3))
        assertEmptySelection(browser)
    }
    func testDirectFlagsRemoveActionTargetsInGridListAndFilmstripAndUndoRestoresMembership() async throws {
        let urls = try photos(), browser = try await browser()
        for mode in [BrowserViewMode.grid, .list, .filmstrip] {
            browser.setMode(mode)
            var filter = BrowserFilter(); filter.unflaggedOnly = true
            browser.contentController.filter = filter
            XCTAssertTrue(browser.contentController.select(url: urls[0]))
            let manager = try XCTUnwrap(browser.window?.undoManager)
            manager.groupsByEvent = false; manager.beginUndoGrouping()
            browser.browserContentRequestsFlag(browser.contentController.selectedItems, flag: true)
            manager.endUndoGrouping(); await CullingUndo.waitForPendingWrites()
            XCTAssertEqual(visible(browser), [urls[1], urls[2]])
            assertEmptySelection(browser)
            manager.undo(); await CullingUndo.waitForPendingWrites()
            XCTAssertEqual(visible(browser), urls)
            XCTAssertEqual(browser.contentController.filter, filter)
        }
    }
    func testCompareRatingResortsByURLAndKeepsSurvivingMultiSelection() async throws {
        let urls = try photos(), browser = try await browser()
        browser.contentController.sort = BrowserSort(key: .rating, direction: .ascending)
        XCTAssertTrue(browser.contentController.select(urls: [urls[0], urls[1]]))
        browser.perform(.compare)
        let compare = try XCTUnwrap(CompareWindow.current)
        compare.rate(5, allPanes: false); await compare.waitForCullingWrites()
        XCTAssertEqual(visible(browser), [urls[1], urls[2], urls[0]])
        XCTAssertEqual(Set(browser.contentController.selectedItems.map(\.url)), Set([urls[0], urls[1]]))
        browser.contentController.filter = BrowserFilter(minimumRating: 4, searchTerm: "bright")
        XCTAssertTrue(browser.contentController.select(url: urls[0]))
        compare.rate(2, allPanes: false); await compare.waitForCullingWrites()
        XCTAssertTrue(visible(browser).isEmpty); assertEmptySelection(browser)
        compare.close()
    }
    func testTagReadbackReconcilesActiveTagFilterAndClearsHiddenSelection() async throws {
        let urls = try photos()
        try FinderTags.write(urls[0], tags: ["Keep"])
        let browser = try await browser()
        browser.contentController.filter = BrowserFilter(searchTerm: "bright", tags: ["Keep"])
        XCTAssertTrue(browser.contentController.select(url: urls[0]))
        try FinderTags.write(urls[0], tags: []); browser.refreshTags(for: [urls[0]])
        XCTAssertTrue(visible(browser).isEmpty); assertEmptySelection(browser)
        try FinderTags.write(urls[2], tags: ["Keep"]); browser.refreshTags(for: [urls[2]])
        XCTAssertEqual(visible(browser), [urls[2]])
        XCTAssertTrue(browser.contentController.selectedItems.isEmpty, "A new matching item must not inherit old selection indices")
        XCTAssertEqual(browser.window?.subtitle, WindowTitles.browserSubtitle(visible: 1, total: 3))
    }
    func testRatingResortPreservesClickedAnchorAndReversedShiftRangeByURL() async throws {
        let urls = try photos(), browser = try await browser()
        let content = browser.contentController
        content.sort = BrowserSort(key: .rating, direction: .ascending)
        let grid = content.collectionViewForTesting
        grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        grid.noteClick(on: IndexPath(item: 0, section: 0), command: false)
        grid.extendSelection(to: IndexPath(item: 1, section: 0))
        XCTAssertEqual(content.selectionAnchorURL, urls[0]); XCTAssertTrue(grid.hasKeyMovingEnd)
        browser.perform(.compare)
        let compare = try XCTUnwrap(CompareWindow.current)
        compare.rate(5, allPanes: false); await compare.waitForCullingWrites()
        XCTAssertEqual(visible(browser), [urls[1], urls[2], urls[0]])
        XCTAssertEqual(Set(content.selectedItems.map(\.url)), Set([urls[0], urls[1]]))
        XCTAssertEqual(content.selectionAnchorURL, urls[0], "Keep the clicked file as the anchor after reordering")
        let range = try XCTUnwrap(grid.keyRange)
        XCTAssertEqual(content.visibleItems[range.anchor.item].url, urls[0])
        XCTAssertEqual(content.visibleItems[range.lead.item].url, urls[1])
        XCTAssertGreaterThan(range.anchor.item, range.lead.item, "The same file range now runs in reverse")
        XCTAssertTrue(grid.hasKeyMovingEnd)
    }
    func testCompareThroughPairedViewerUpdatesFlaggedMembership() async throws {
        let urls = try photos(), browser = try await browser()
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewers.append(viewer); viewer.pairedBrowser = browser; browser.pairedViewer = viewer
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem != nil }
        browser.contentController.filter = BrowserFilter(flaggedOnly: true)
        let compare = CompareWindow.open(.init(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: services, origin: viewer, frame: nil)
        compare.toggleFlag(allPanes: false); await compare.waitForCullingWrites()
        XCTAssertEqual(visible(browser), [urls[0]])
        XCTAssertEqual(browser.contentController.filter, BrowserFilter(flaggedOnly: true))
        compare.toggleFlag(allPanes: false); await compare.waitForCullingWrites()
        XCTAssertTrue(visible(browser).isEmpty); assertEmptySelection(browser)
    }
    func testOldFolderCommitCannotChangeNewFolderMembershipOrSelection() async throws {
        let urls = try photos(), browser = try await browser()
        XCTAssertTrue(browser.contentController.select(url: urls[0]))
        CullingUndo.beforeWriteForTesting = { [weak self] in
            await withCheckedContinuation { self?.heldHydration = $0 }
        }
        browser.browserContentRequestsRate(browser.contentController.selectedItems, to: 4)
        try await until { self.heldHydration != nil }
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = other.appendingPathComponent("target.jpg"); try FileManager.default.copyItem(at: urls[1], to: target)
        var filter = BrowserFilter(); filter.unratedOnly = true
        browser.contentController.filter = filter
        browser.navigate(to: other); await browser.listingTask?.value
        XCTAssertEqual(visible(browser), [target])
        heldHydration?.resume(); heldHydration = nil
        CullingUndo.beforeWriteForTesting = nil
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(visible(browser), [target]); XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [target])
        XCTAssertEqual(browser.contentController.filter, filter); XCTAssertEqual(browser.currentFolder, other.standardizedFileURL)
    }
    func testHeldOldHydrationCannotReinsertNewlyRatedOrUntaggedItems() async throws {
        let urls = try photos(); try FinderTags.write(urls[0], tags: ["Keep"])
        let browser = try await browser(holdHydration: true)
        var filter = BrowserFilter(); filter.unratedOnly = true
        browser.contentController.filter = filter; XCTAssertTrue(browser.contentController.select(url: urls[0]))
        browser.browserContentRequestsRate(browser.contentController.selectedItems, to: 4)
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(visible(browser), [urls[1], urls[2]])
        try FinderTags.write(urls[0], tags: []); browser.refreshTags(for: [urls[0]])
        heldHydration?.resume(); heldHydration = nil
        var landed = false; browser.onHydratedForTesting = { landed = true }
        try await until { landed }
        XCTAssertEqual(visible(browser), [urls[1], urls[2]])
        XCTAssertEqual(browser.contentController.allItems.first?.rating, 4)
        XCTAssertEqual(browser.contentController.allItems.first?.tags, [])
        assertEmptySelection(browser)
    }
}

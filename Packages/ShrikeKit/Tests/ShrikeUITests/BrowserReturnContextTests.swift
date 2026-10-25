import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

private actor ReturnContextListingGate {
    private var requests: [CheckedContinuation<[BrowserItem], any Error>?] = []
    private var closed = false
    func scan() async throws -> [BrowserItem] {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { requests.append($0) }
    }
    var count: Int { requests.count }
    func finish(_ index: Int, with items: [BrowserItem]) {
        requests[index]?.resume(returning: items); requests[index] = nil
    }
    func releaseAll() {
        closed = true
        for request in requests { request?.resume(throwing: CancellationError()) }
        requests = []
    }
}

@MainActor
final class BrowserReturnContextTests: XCTestCase {
    private enum ControlledWorkError: Error { case didNotSettle }
    private var root: URL!
    private var a: URL!, b: URL!
    private var photo: URL!, broken: URL!
    private var services: ShrikeServices!
    private var coordinator: WindowCoordinator!
    private var extraBrowsers: [BrowserWindowController] = []
    private var gate: ReturnContextListingGate?
    private var hydration: CheckedContinuation<Void, Never>?
    private var isTearingDown = false
    private var savedHint = false
    private var savedMotion: Bool?

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-return-context-\(UUID())")
        a = root.appendingPathComponent("Folder-A", isDirectory: true)
        b = root.appendingPathComponent("CorruptOnly-B", isDirectory: true)
        for folder in [a!, b!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        photo = a.appendingPathComponent("photo.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 400, height: 300), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        broken = b.appendingPathComponent("broken.jpg")
        try Data("Not a decodable photo".utf8).write(to: broken)
        services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        coordinator = WindowCoordinator()
        savedHint = Prefs.hasSeenBrowserReturnHint; Prefs.hasSeenBrowserReturnHint = true
        savedMotion = ReduceMotion.overrideForTesting; ReduceMotion.overrideForTesting = true
    }

    override func tearDown() async throws {
        isTearingDown = true
        for browser in coordinator.browsers + extraBrowsers { browser.hydrationGateForTesting = nil }
        hydration?.resume(); hydration = nil
        await gate?.releaseAll()
        for viewer in coordinator.viewers { viewer.close() }
        for browser in coordinator.browsers { browser.close() }
        extraBrowsers.forEach { $0.close() }; extraBrowsers = []
        await services.thumbnailCache.waitForPendingDiskWrites()
        await services.thumbnailCache.evictMemory()
        Prefs.hasSeenBrowserReturnHint = savedHint
        ReduceMotion.overrideForTesting = savedMotion
        try? FileManager.default.removeItem(at: root)
    }

    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let settled = await condition()
        guard settled else {
            XCTFail("Controlled pairing/listing/decode must settle", file: file, line: line)
            throw ControlledWorkError.didNotSettle
        }
    }

    private func openPair(_ browser: BrowserWindowController) async throws -> ViewerWindow {
        let viewer = try XCTUnwrap(coordinator.openPairedViewer(from: browser,
            groups: browser.contentController.visibleItems.map(\.group), startIndex: 0))
        viewer.setContentSize(NSSize(width: 1200, height: 700))
        let bar = try XCTUnwrap(viewer.toolbarController)
        bar.toolbar.autosavesConfiguration = false; bar.toolbar.isVisible = true
        if !bar.toolbar.items.contains(where: { $0.itemIdentifier == ViewerWindowToolbar.ID.showInBrowser }) {
            bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.showInBrowser, at: 0)
        }
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == self.photo }
        return viewer
    }

    private func assertTitle(_ viewer: ViewerWindow, folder: URL?, nativeAX: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let title = folder.map { "Back to \($0.lastPathComponent)" } ?? "Show in Browser"
        let bar = try XCTUnwrap(viewer.toolbarController, file: file, line: line)
        let item = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.showInBrowser), file: file, line: line)
        XCTAssertEqual(item.label, title, file: file, line: line)
        let key = ShortcutTable.displayString(for: .showInBrowser, context: .viewer, preset: Prefs.shortcutPreset)
        XCTAssertEqual(item.toolTip, title + " · " + key, file: file, line: line)
        if let overflow = item.menuFormRepresentation { XCTAssertEqual(overflow.title, title, file: file, line: line) }
        if let view = item.view { XCTAssertEqual(view.accessibilityLabel(), title, file: file, line: line) }
        if nativeAX {
            viewer.contentView?.superview?.layoutSubtreeIfNeeded()
            func toolbarView(_ view: NSView) -> NSView? {
                if view.accessibilityRole() == .toolbar { return view }
                for child in view.subviews { if let found = toolbarView(child) { return found } }
                return nil
            }
            let toolbar = try XCTUnwrap(viewer.contentView?.superview.flatMap(toolbarView), file: file, line: line)
            let labels = (toolbar.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() }
            XCTAssertTrue(labels.contains(title), "Native toolbar AX must identify the current return destination: \(labels)", file: file, line: line)
        }
    }

    func testCoordinatorReuseForCorruptOnlyFolderRefreshesSeenHintContextAndUnpair() async throws {
        let originalA = try Data(contentsOf: photo), originalB = try Data(contentsOf: broken)
        let browser = coordinator.openBrowser(at: a, selecting: photo, services: services)
        await browser.listingTask?.value
        let viewer = try await openPair(browser)
        try assertTitle(viewer, folder: a, nativeAX: true)
        viewer.perform(.showInBrowser)
        browser.go(to: .folder(b))
        try assertTitle(viewer, folder: b, nativeAX: true) // synchronous acceptance, before any B pixel
        await browser.listingTask?.value
        let reused = try XCTUnwrap(coordinator.openPairedViewer(from: browser,
            groups: browser.contentController.visibleItems.map(\.group), startIndex: 0))
        XCTAssertTrue(reused === viewer)
        try await until { viewer.navCoalescer.isIdle && viewer.contentRoot.isShowingDecodeError }
        XCTAssertEqual(viewer.displayedItem?.group.primary, broken)
        XCTAssertTrue(Prefs.hasSeenBrowserReturnHint)
        XCTAssertNil(viewer.returnHintPopover, "Persistent context refresh must not replay onboarding")
        try assertTitle(viewer, folder: b, nativeAX: true)
        viewer.perform(.showInBrowser)
        XCTAssertEqual(browser.currentFolder, b)
        XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [broken!])
        viewer.showFromBrowser(groups: [ImageGroup(primary: broken)], startIndex: 0)
        try await until { viewer.navCoalescer.isIdle && viewer.contentRoot.isShowingDecodeError }
        let recovery = viewer.contentRoot.errorOverlayForTesting.nextButton
        XCTAssertEqual(recovery.title, "Back to Browser"); recovery.performClick(nil)
        XCTAssertEqual(browser.currentFolder, b)
        XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [broken!])

        let bar = try XCTUnwrap(viewer.toolbarController)
        let index = try XCTUnwrap(bar.toolbar.items.firstIndex { $0.itemIdentifier == ViewerWindowToolbar.ID.showInBrowser })
        bar.toolbar.removeItem(at: index)
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.showInBrowser, at: index)
        try assertTitle(viewer, folder: b)
        // A customization/palette item is a freshly made item, not the built-item cache.
        let palette = try XCTUnwrap(bar.toolbar(bar.toolbar, itemForItemIdentifier: ViewerWindowToolbar.ID.showInBrowser, willBeInsertedIntoToolbar: false))
        XCTAssertEqual(palette.label, "Back to \(b.lastPathComponent)")
        XCTAssertEqual(palette.toolTip, bar.item(ViewerWindowToolbar.ID.showInBrowser)?.toolTip)
        browser.close()
        XCTAssertNil(viewer.pairedBrowser)
        try assertTitle(viewer, folder: nil)
        XCTAssertEqual(try Data(contentsOf: photo), originalA)
        XCTAssertEqual(try Data(contentsOf: broken), originalB)
    }

    func testAcceptedContextSurvivesOldHydrationReloadHistoryAndReadError() async throws {
        let browser = coordinator.openBrowser(at: a, selecting: photo, services: services)
        await browser.listingTask?.value
        let viewer = try await openPair(browser)
        browser.hydrationGateForTesting = { [weak self] in
            guard let self, !self.isTearingDown, self.hydration == nil else { return }
            await withCheckedContinuation { self.hydration = $0 }
        }
        browser.reloadCurrentFolder()
        let oldTask = browser.listingTask
        try await until { self.hydration != nil }
        browser.hydrationGateForTesting = nil
        browser.navigate(to: b)
        try assertTitle(viewer, folder: b)
        await browser.listingTask?.value
        hydration?.resume(); hydration = nil
        await oldTask?.value
        try assertTitle(viewer, folder: b)
        browser.reloadCurrentFolder(); try assertTitle(viewer, folder: b)
        await browser.listingTask?.value
        browser.goBack(); try assertTitle(viewer, folder: a)
        await browser.listingTask?.value
        browser.goForward(); try assertTitle(viewer, folder: b)
        await browser.listingTask?.value
        let missing = root.appendingPathComponent("Unavailable-Folder")
        browser.navigate(to: missing); try assertTitle(viewer, folder: missing)
        await browser.listingTask?.value
        XCTAssertEqual(browser.contentController.emptyStateForTesting?.buttonTitle, "Go to Enclosing Folder")
        try assertTitle(viewer, folder: missing)
        XCTAssertTrue(Prefs.hasSeenBrowserReturnHint)
    }

    func testLateOldListingCannotRestorePreviousReturnDestination() async throws {
        let gate = ReturnContextListingGate(); self.gate = gate
        let browser = BrowserWindowController(services: services, initialFolder: a,
            folderEnumerator: { _, _ in try await gate.scan() })
        extraBrowsers.append(browser)
        try await until { await gate.count == 1 }
        func item(_ url: URL) -> BrowserItem {
            BrowserItem(url: url, displayName: url.lastPathComponent, fileSize: 1,
                modificationDate: Date(), creationDate: nil, captureDate: nil, utType: .jpeg,
                pixelWidth: nil, pixelHeight: nil)
        }
        await gate.finish(0, with: [item(photo)])
        await browser.listingTask?.value
        let viewer = try await openPair(browser)
        browser.reloadCurrentFolder()
        let oldTask = browser.listingTask
        try await until { await gate.count == 2 }
        browser.navigate(to: b); try assertTitle(viewer, folder: b)
        try await until { await gate.count == 3 }
        await gate.finish(2, with: [item(broken)])
        await browser.listingTask?.value
        await gate.finish(1, with: [item(photo)])
        await oldTask?.value
        XCTAssertEqual(browser.currentFolder, b)
        XCTAssertEqual(browser.contentController.visibleItems.map(\.url), [broken!])
        try assertTitle(viewer, folder: b)
    }
    func testUnavailableReturnAnchorDefersFirstHintWithoutMarkingSeen() async throws {
        let browser = coordinator.openBrowser(at: a, selecting: photo, services: services)
        await browser.listingTask?.value
        let viewer = try await openPair(browser)
        let bar = try XCTUnwrap(viewer.toolbarController)
        bar.toolbar.isVisible = false
        Prefs.hasSeenBrowserReturnHint = false
        viewer.contentRoot.imageView.onFirstImagePresented?()
        XCTAssertTrue(viewer.browserReturnHintReady)
        XCTAssertNil(viewer.returnHintPopover)
        XCTAssertFalse(Prefs.hasSeenBrowserReturnHint)
        let index = try XCTUnwrap(bar.toolbar.items.firstIndex { $0.itemIdentifier == ViewerWindowToolbar.ID.showInBrowser })
        bar.toolbar.removeItem(at: index)
        bar.toolbar.isVisible = true
        viewer.contentView?.superview?.layoutSubtreeIfNeeded()
        viewer.showBrowserReturnHint()
        XCTAssertNil(viewer.returnHintPopover)
        XCTAssertFalse(Prefs.hasSeenBrowserReturnHint)
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.showInBrowser, at: 0)
        viewer.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(bar.returnAnchor, "A reinserted visible real return button can teach later")
        // Native complete popup pixels are verified separately; no fabricated
        // fallback is allowed to consume onboarding while its control is absent.
        Prefs.hasSeenBrowserReturnHint = true
    }

    func testFirstReturnHintFitsPaddedShortAndLongTextAtBothChromeSizes() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        let copies = ["Back to Images · ⌘B, ⌘↑",
                      "Torna alla cartella delle immagini delle vacanze e dei ricordi di famiglia · ⌘B, ⌘↑"]
        for larger in [false, true] {
            Prefs.largerChrome = larger
            for text in copies {
                let controller = BrowserReturnHintController(text: text)
                let container = controller.view
                let label = try XCTUnwrap(container.subviews.compactMap { $0 as? NSTextField }.first)
                container.layoutSubtreeIfNeeded()
                XCTAssertFalse(container is NSTextField, "The popover needs a padded container around its text")
                XCTAssertEqual(label.stringValue, text)
                XCTAssertGreaterThanOrEqual(label.frame.minX, 12)
                XCTAssertGreaterThanOrEqual(container.bounds.maxX - label.frame.maxX, 12)
                XCTAssertGreaterThanOrEqual(label.frame.minY, 10)
                XCTAssertGreaterThanOrEqual(container.bounds.maxY - label.frame.maxY, 10)
                let font = try XCTUnwrap(label.font)
                let glyphs = (text as NSString).boundingRect(with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                XCTAssertGreaterThanOrEqual(label.bounds.height + 1, ceil(glyphs.height),
                                             "All wrapped lines must fit inside the label")
                XCTAssertEqual(controller.preferredContentSize, container.frame.size)
                if text == copies.last { XCTAssertGreaterThan(container.frame.height, 48, "Long copy must grow vertically") }
            }
        }
    }

    func testOpenFirstReturnHintRefitsAfterLargerChromeChanges() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = false
        let controller = BrowserReturnHintController(text: "Back to a folder with a longer descriptive name · ⌘B, ⌘↑")
        let container = controller.view
        let label = try XCTUnwrap(container.subviews.compactMap { $0 as? NSTextField }.first)
        let before = try XCTUnwrap(label.font).pointSize
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(label.font?.pointSize, before + 2)
        XCTAssertEqual(controller.preferredContentSize, container.frame.size)
        let glyphs = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: try XCTUnwrap(label.font)])
        XCTAssertGreaterThanOrEqual(label.bounds.height + 1, ceil(glyphs.height))
    }

}

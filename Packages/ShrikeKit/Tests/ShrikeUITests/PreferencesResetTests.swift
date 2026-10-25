//
//  PreferencesResetTests.swift
//  ShrikeUITests
//
//  Two behaviours under test:
//    1. Per-tab `resetToDefaults()` clears *only* the keys owned by that tab.
//       Other keys stay mutated.
//    2. Global `Prefs.resetAll()` clears everything (already covered in
//       PrefsTests but we exercise it from the UI side for regression
//       coverage).
//

import XCTest
import AppKit
import ImageIO
@testable import ShrikeUI
import ShrikeCore
import ShrikeIO

final class PreferencesResetTests: XCTestCase {
    private var ownedThumbnailRoots: [URL] = []
    private var savedDefaultsDomain: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        guard let suite = ShrikeDefaults.testSuiteName else {
            XCTFail("Reset tests require the process-local XCTest defaults suite")
            return
        }
        savedDefaultsDomain = ShrikeDefaults.store.persistentDomain(forName: suite) ?? [:]
        Prefs.resetAll()
    }

    override func tearDown() async throws {
        for root in ownedThumbnailRoots { try? FileManager.default.removeItem(at: root) }
        ownedThumbnailRoots.removeAll()
        if let suite = ShrikeDefaults.testSuiteName {
            ShrikeDefaults.store.setPersistentDomain(savedDefaultsDomain, forName: suite)
            ShrikeDefaults.store.synchronize()
        }
        savedDefaultsDomain.removeAll()
        // Restore cached consumers too, through their normal UI notifications.
        await MainActor.run {
            NotificationCenter.default.post(name: .shrikeThumbnailSizeChanged, object: nil)
            NotificationCenter.default.post(name: .shrikeToolbarAutoHideChanged, object: nil)
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
            NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
        }
        await Task.yield()
        try await super.tearDown()
    }

    // MARK: - Per-tab reset isolation

    @MainActor
    func testGeneralResetKeys_coverThreeGeneralControls() {
        // The resetKeys list is part of the UI contract — the General tab
        // promises to restore exactly these three schema keys.
        XCTAssertEqual(
            Set(PreferencesTab.general.resetKeys),
            Set([
                "shrike.browser.showHiddenFiles",
                "shrike.recent.foldersLimit",
                "shrike.input.scrollWheelNavigates",
                "shrike.grouping.pairRAW",
                "shrike.metadata.writeFileAttributes",
                "shrike.viewer.toolbarAutoHide", "shrike.viewer.backgroundAlwaysBlack",
                "shrike.viewer.positionOverlayAutoHides", "shrike.accessibility.largerChrome",
                "shrike.review.controlsVisible", "shrike.review.advanceAfterRating",
            ])
        )
    }

    @MainActor
    func testGeneralReset_clearsGeneralKeysOnly() {
        // Mutate one key per tab.
        Prefs.showHiddenFiles = true                 // General
        Prefs.thumbnailSizePt = 256                  // Thumbnails
        Prefs.maxDisplayLongEdge = 8192              // Performance
        Prefs.viewerBackgroundAlwaysBlack = false    // Advanced
        Prefs.externalEditors = [                    // External editors
            ExternalEditorSlot(name: "X", bundleIdentifierOrPath: "/A.app", shortcut: nil)
        ]
        Prefs.shortcutPreset = .fastStoneCompat      // Shortcuts

        PreferencesTab.general.resetToDefaults()

        // General keys → defaults.
        XCTAssertFalse(Prefs.showHiddenFiles)

        // Every other tab's key → unchanged.
        XCTAssertEqual(Prefs.thumbnailSizePt, 256)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 8192)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.externalEditors.count, 1)
        XCTAssertEqual(Prefs.shortcutPreset, .fastStoneCompat)
    }

    @MainActor
    func testThumbnailsReset_clearsThumbnailsKeysOnly() {
        Prefs.thumbnailSizePt = 256
        Prefs.cacheDiskCeilingBytes = 2 * 1024 * 1024 * 1024
        Prefs.showHiddenFiles = true  // poison from another tab

        PreferencesTab.thumbnails.resetToDefaults()

        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, 512 * 1024 * 1024)
        // General's key should NOT be touched by a Thumbnails-only reset.
        XCTAssertTrue(Prefs.showHiddenFiles,
                      "Thumbnails reset must not touch General keys")
    }

    @MainActor
    func testPerformanceReset_clearsOnlyMaxDisplayLongEdge() {
        Prefs.maxDisplayLongEdge = 8192
        Prefs.viewerBackgroundAlwaysBlack = false  // Advanced key

        PreferencesTab.performance.resetToDefaults()

        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack,
                       "Performance reset must not touch Advanced keys")
    }

    @MainActor
    func testAdvancedReset_clearsViewerTogglesOnly() {
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.viewerPositionOverlayAutoHides = false   // General owns viewing controls
        Prefs.maxDisplayLongEdge = 8192
        Prefs.thumbnailSizePt = 256  // poison

        PreferencesTab.advanced.resetToDefaults()

        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)   // default off
        XCTAssertFalse(Prefs.viewerPositionOverlayAutoHides)   // General is untouched
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertEqual(Prefs.thumbnailSizePt, 256,
                       "Advanced reset must not touch Thumbnails keys")
    }

    @MainActor
    func testShortcutsReset_onlyClearsPreset() {
        Prefs.shortcutPreset = .fastStoneCompat
        Prefs.thumbnailSizePt = 256

        PreferencesTab.shortcuts.resetToDefaults()

        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
        XCTAssertEqual(Prefs.thumbnailSizePt, 256)
    }

    @MainActor
    func testExternalEditorsReset_clearsRegistryAndOldList() throws {
        let defaults = ShrikeDefaults.store
        Prefs.externalEditors = [
            ExternalEditorSlot(name: "X", bundleIdentifierOrPath: "/A.app", shortcut: nil)
        ]
        let registry = ExternalEditorRegistry(defaults: defaults)
        ExternalEditors.registry = registry
        defer { ExternalEditors.resetRegistryForTesting() }
        try registry.add(ExternalEditor(displayName: "Y", bundleIdentifier: nil,
                                        applicationURL: URL(fileURLWithPath: "/B.app")))
        XCTAssertNotNil(defaults.object(forKey: ExternalEditorRegistry.defaultsKey))

        PreferencesTab.externalEditors.resetToDefaults()

        XCTAssertTrue(Prefs.externalEditors.isEmpty)
        XCTAssertTrue(registry.editors.isEmpty, "the live registry is cleared too")
        XCTAssertNil(defaults.object(forKey: ExternalEditorRegistry.defaultsKey))
        XCTAssertNil(defaults.object(forKey: ExternalEditorRegistry.legacyDefaultsKey))
    }

    // MARK: - Global reset

    @MainActor
    func testResetAll_fromUISide_clearsEverything() {
        Prefs.showHiddenFiles = true
        Prefs.thumbnailSizePt = 256
        Prefs.maxDisplayLongEdge = 8192
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.shortcutPreset = .fastStoneCompat

        Prefs.resetAll()

        XCTAssertFalse(Prefs.showHiddenFiles)
        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
    }
    @MainActor
    private final class ThumbnailResetNotifications: NSObject {
        var sizes: [Int] = []
        @objc func didChange(_ note: Notification) { sizes.append(Prefs.thumbnailSizePt) }
    }

    @MainActor
    private func thumbnailResetBrowser(includeResetAllFiles: Bool = false) async throws -> BrowserWindowController {
        let root = TestScratch.directory.appendingPathComponent("shrike-thumbnail-reset-\(UUID())")
        ownedThumbnailRoots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        var expected = (0..<3).map { root.appendingPathComponent("photo-\($0).png") }
        for url in expected {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        if includeResetAllFiles {
            let hidden = root.appendingPathComponent(".hidden.png")
            try FileManager.default.copyItem(at: expected[0], to: hidden)
            let jpeg = root.appendingPathComponent("pair.JPG"), raw = root.appendingPathComponent("pair.ORF")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try Data([0x4f, 0x52, 0x46]).write(to: raw)
            expected += [hidden, jpeg, raw]
            expected.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: root)
        do {
            await browser.listingTask?.value
            XCTAssertEqual(browser.contentController.visibleItems.map(\.url), expected, "the Browser must contain the three owned fixture files")
            guard browser.contentController.visibleItems.map(\.url) == expected else {
                throw NSError(domain: "PreferencesResetTests.ownedListing", code: 1)
            }
            browser.contentController.setMode(.grid)
            let window = try XCTUnwrap(browser.window)
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            return browser
        } catch {
            browser.close()
            throw error
        }
    }

    @MainActor
    private func assertThumbnailGridSize(_ size: Int, browser: BrowserWindowController,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let content = browser.contentController, grid = content.collectionViewForTesting
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        content.view.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(grid.collectionViewLayout as? NSCollectionViewFlowLayout, file: file, line: line)
        let cell = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)), file: file, line: line)
        XCTAssertEqual(Prefs.thumbnailSizePt, size, file: file, line: line)
        XCTAssertEqual(browser.thumbSizeSlider.integerValue, size, file: file, line: line)
        XCTAssertEqual(content.thumbnailPixelSize, size, file: file, line: line)
        XCTAssertEqual(layout.itemSize.width, CGFloat(size), file: file, line: line)
        XCTAssertEqual(cell.frame.width, CGFloat(size), file: file, line: line)
    }

    @MainActor
    func testThumbnailsResetUpdatesExistingBrowserSliderAndOwnedGridWithoutLosingSelection() async throws {
        let browser = try await thumbnailResetBrowser()
        defer { browser.close() }
        let content = browser.contentController, grid = content.collectionViewForTesting
        let notifications = ThumbnailResetNotifications()
        NotificationCenter.default.addObserver(notifications, selector: #selector(ThumbnailResetNotifications.didChange(_:)),
            name: .shrikeThumbnailSizeChanged, object: nil)
        defer { NotificationCenter.default.removeObserver(notifications) }
        let store = PreferencesStore()
        store.thumbnailSizePt.wrappedValue = 210
        try assertThumbnailGridSize(210, browser: browser)
        XCTAssertEqual(notifications.sizes, [210], "normal binding updates the actual existing Browser")
        let selection: Set<IndexPath> = [IndexPath(item: 1, section: 0)]
        XCTAssertTrue(content.select(url: content.visibleItems[1].url))
        grid.noteClick(on: IndexPath(item: 1, section: 0), command: false)
        let items = content.visibleItems.map(\.url), selected = content.selectedItems.map(\.url)
        let anchor = content.selectionAnchorURL
        XCTAssertEqual(selected, [items[1]], "positive control: a real owned item is selected")
        XCTAssertEqual(anchor, items[1])
        Prefs.showHiddenFiles = true
        store.notifyAndMutate { PreferencesTab.thumbnails.resetToDefaults() }
        try assertThumbnailGridSize(180, browser: browser)
        XCTAssertEqual(notifications.sizes, [210, 180], "the reset notification observes the removed key's180 default")
        XCTAssertEqual(content.visibleItems.map(\.url), items)
        XCTAssertEqual(content.selectedItems.map(\.url), selected)
        XCTAssertEqual(grid.selectionIndexPaths, selection)
        XCTAssertEqual(content.selectionAnchorURL, anchor)
        XCTAssertTrue(Prefs.showHiddenFiles, "the other tab's preference is preserved")
    }

    @MainActor
    func testGeneralResetDoesNotNotifyOrResizeAnExistingThumbnailGrid() async throws {
        let browser = try await thumbnailResetBrowser()
        defer { browser.close() }
        let notifications = ThumbnailResetNotifications()
        NotificationCenter.default.addObserver(notifications, selector: #selector(ThumbnailResetNotifications.didChange(_:)),
            name: .shrikeThumbnailSizeChanged, object: nil)
        defer { NotificationCenter.default.removeObserver(notifications) }
        let store = PreferencesStore()
        store.thumbnailSizePt.wrappedValue = 210
        try assertThumbnailGridSize(210, browser: browser)
        Prefs.showHiddenFiles = true
        store.notifyAndMutate { PreferencesTab.general.resetToDefaults() }
        XCTAssertFalse(Prefs.showHiddenFiles, "positive control: the General reset actually ran")
        XCTAssertEqual(notifications.sizes, [210], "an unrelated tab reset sends no thumbnail change")
        try assertThumbnailGridSize(210, browser: browser)
    }

    @MainActor
    private final class ResetSignals: NSObject {
        var names: [Notification.Name] = []
        @objc func changed(_ note: Notification) { names.append(note.name) }
    }

    @MainActor
    private func waitForResetState(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "existing cached consumer must follow the reset")
    }

    @MainActor
    private func resetViewer(for browser: BrowserWindowController) throws -> ViewerWindow {
        let item = try XCTUnwrap(browser.contentController.visibleItems.first { $0.url.lastPathComponent == "photo-1.png" })
        let viewer = ViewerWindow(groups: [ImageGroup(primary: item.url)], startIndex: 0, services: .makeDefault())
        viewer.setContentSize(NSSize(width: 900, height: 600))
        return viewer
    }

    @MainActor
    private func assertViewerAutoHide(_ enabled: Bool, viewer: ViewerWindow, hider: TitlebarAutoHider,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let content = viewer.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(viewer.autoHider === hider, "the same Viewer/hider instance is updated", file: file, line: line)
        XCTAssertEqual(Prefs.viewerToolbarAutoHide, enabled, file: file, line: line)
        XCTAssertEqual(hider.isEnabled, enabled, file: file, line: line)
        XCTAssertEqual(viewer.titlebarAppearsTransparent, hider.isActive, file: file, line: line)
        if hider.container != nil {
            XCTAssertEqual(hider.isActive, enabled, file: file, line: line)
            XCTAssertEqual(viewer.titlebarSeparatorStyle, enabled ? .none : .automatic, file: file, line: line)
            if enabled {
                XCTAssertEqual(content.imageView.frame.maxY, content.bounds.maxY, accuracy: 0.5, file: file, line: line)
            }
        }
    }

    @MainActor
    func testGeneralResetUpdatesExistingViewerAutoHideWithoutResettingThumbnailSize() async throws {
        let browser = try await thumbnailResetBrowser()
        defer { browser.close() }
        let viewer = try resetViewer(for: browser)
        defer { viewer.close() }
        let hider = try XCTUnwrap(viewer.autoHider), store = PreferencesStore()
        XCTAssertTrue(hider.isEnabled)
        store.thumbnailSizePt.wrappedValue = 210
        store.viewerToolbarAutoHide.wrappedValue = false
        try await waitForResetState { !hider.isEnabled }
        assertViewerAutoHide(false, viewer: viewer, hider: hider)
        store.notifyAndMutate { PreferencesTab.general.resetToDefaults() }
        try await waitForResetState { hider.isEnabled }
        assertViewerAutoHide(true, viewer: viewer, hider: hider)
        try assertThumbnailGridSize(210, browser: browser)
    }

    @MainActor
    func testActualResetAllHandlerRelistsExistingBrowserAndUpdatesViewerCaches() async throws {
        let store = PreferencesStore()
        store.showHiddenFiles.wrappedValue = true
        store.pairRAW.wrappedValue = false
        let browser = try await thumbnailResetBrowser(includeResetAllFiles: true)
        defer { browser.close() }
        let viewer = try resetViewer(for: browser)
        defer { viewer.close() }
        let hider = try XCTUnwrap(viewer.autoHider), content = browser.contentController
        let folder = try XCTUnwrap(browser.currentFolder)
        XCTAssertEqual(content.visibleItems.count, 6)
        XCTAssertTrue(content.visibleItems.contains { $0.url.lastPathComponent == ".hidden.png" })
        XCTAssertEqual(content.visibleItems.filter { $0.url.lastPathComponent.hasPrefix("pair.") }.count, 2)
        store.thumbnailSizePt.wrappedValue = 210
        store.viewerToolbarAutoHide.wrappedValue = false
        try await waitForResetState { !hider.isEnabled }
        try assertThumbnailGridSize(210, browser: browser)
        let selected = folder.appendingPathComponent("photo-1.png")
        XCTAssertTrue(content.select(url: selected))
        XCTAssertEqual(content.selectedItems.map(\.url), [selected])
        let beforeGeneration = browser.folderRequestGeneration
        // Invoke the same production handler used by Advanced's confirmed Reset.
        AdvancedTab.resetAllPreferences(using: store)
        let expected = Set(["photo-0.png", "photo-1.png", "photo-2.png", "pair.JPG"])
        let deadline = Date().addingTimeInterval(5)
        while (Set(content.visibleItems.map { $0.url.lastPathComponent }) != expected || !hider.isEnabled), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(browser.folderRequestGeneration, beforeGeneration)
        XCTAssertEqual(browser.currentFolder, folder)
        XCTAssertEqual(Set(content.visibleItems.map { $0.url.lastPathComponent }), expected)
        let pair = try XCTUnwrap(content.visibleItems.first { $0.url.lastPathComponent == "pair.JPG" })
        XCTAssertTrue(pair.group.hasRAW, "the real re-list uses restored RAW+JPEG grouping")
        XCTAssertTrue(ImageGroupingPreference.isEnabled)
        XCTAssertFalse(Prefs.showHiddenFiles)
        XCTAssertEqual(content.selectedItems.map(\.url), [selected], "a still-visible owned selection survives the reset re-list")
        try assertThumbnailGridSize(180, browser: browser)
        assertViewerAutoHide(true, viewer: viewer, hider: hider)
    }

    @MainActor
    func testEditingAndAdvancedTabResetsLeaveUnownedCachedPoliciesAlone() async throws {
        let browser = try await thumbnailResetBrowser()
        defer { browser.close() }
        let viewer = try resetViewer(for: browser)
        defer { viewer.close() }
        let hider = try XCTUnwrap(viewer.autoHider), store = PreferencesStore()
        store.thumbnailSizePt.wrappedValue = 210
        store.viewerToolbarAutoHide.wrappedValue = false
        store.pairRAW.wrappedValue = false
        try await waitForResetState { !hider.isEnabled }
        let signals = ResetSignals()
        for name in [Notification.Name.shrikeThumbnailSizeChanged, .shrikeToolbarAutoHideChanged, .shrikeGroupingDidChange] {
            NotificationCenter.default.addObserver(signals, selector: #selector(ResetSignals.changed(_:)), name: name, object: nil)
        }
        defer { NotificationCenter.default.removeObserver(signals) }
        let jpegDefault = Prefs.editJPEGQualityDefault
        Prefs.editJPEGQualityDefault = 60
        Prefs.maxDisplayLongEdge = 8192
        store.notifyAndMutate { PreferencesTab.editing.resetToDefaults() }
        XCTAssertEqual(Prefs.editJPEGQualityDefault, jpegDefault, "positive control: Editing actually resets its owned key")
        store.notifyAndMutate { PreferencesTab.advanced.resetToDefaults() }
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096, "positive control: Advanced actually resets its owned key")
        XCTAssertTrue(signals.names.isEmpty, "neither tab owns thumbnail, toolbar or grouping policy")
        XCTAssertFalse(ImageGroupingPreference.isEnabled)
        try assertThumbnailGridSize(210, browser: browser)
        assertViewerAutoHide(false, viewer: viewer, hider: hider)
    }

    @MainActor
    private func hiddenPolicyFixture() throws -> (folder: URL, visible: URL, hidden: URL) {
        let folder = TestScratch.directory.appendingPathComponent("shrike-hidden-policy-\(UUID())", isDirectory: true).standardizedFileURL
        ownedThumbnailRoots.append(folder)
        for name in ["VisibleBranch/Nested", ".HiddenFolder", "Collapsed/DoNotWalk"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let visible = folder.appendingPathComponent("Visible.png"), hidden = folder.appendingPathComponent(".Hidden.png")
        try SaveFlowTests.writeImage(visible, type: .png)
        try FileManager.default.copyItem(at: visible, to: hidden)
        return (folder, visible, hidden)
    }

    @MainActor
    private func selectHiddenPolicyControl(_ url: URL, browser: BrowserWindowController) throws {
        let content = browser.contentController
        content.setMode(.grid)
        XCTAssertTrue(content.select(url: url))
        let index = try XCTUnwrap(content.visibleItems.firstIndex { $0.url == url })
        content.collectionViewForTesting.noteClick(on: IndexPath(item: index, section: 0), command: false)
        XCTAssertEqual(content.selectedItems.map(\.url), [url])
        XCTAssertEqual(content.selectionAnchorURL, url)
    }

    @MainActor
    func testNormalShowHiddenBindingRefreshesTwoExistingBrowsersAndKeepsSelections() async throws {
        let first = try hiddenPolicyFixture(), second = try hiddenPolicyFixture()
        let a = BrowserWindowController(services: .makeDefault(), initialFolder: first.folder)
        defer { a.close() }
        let b = BrowserWindowController(services: .makeDefault(), initialFolder: second.folder)
        defer { b.close() }
        try await waitForResetState {
            a.contentController.visibleItems.map(\.url) == [first.visible]
                && b.contentController.visibleItems.map(\.url) == [second.visible]
        }
        try selectHiddenPolicyControl(first.visible, browser: a)
        try selectHiddenPolicyControl(second.visible, browser: b)
        let store = PreferencesStore()
        for show in [true, false] {
            let generations = [a.folderRequestGeneration, b.folderRequestGeneration]
            store.showHiddenFiles.wrappedValue = show
            try await waitForResetState {
                Set(a.contentController.visibleItems.map(\.url)) == Set(show ? [first.visible, first.hidden] : [first.visible])
                    && Set(b.contentController.visibleItems.map(\.url)) == Set(show ? [second.visible, second.hidden] : [second.visible])
            }
            for (index, entry) in [(a, first), (b, second)].enumerated() {
                let (browser, fixture) = entry
                XCTAssertGreaterThan(browser.folderRequestGeneration, generations[index])
                XCTAssertEqual(browser.currentFolder, fixture.folder)
                XCTAssertEqual(browser.window?.representedURL, fixture.folder)
                XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [fixture.visible])
                XCTAssertEqual(browser.contentController.selectionAnchorURL, fixture.visible)
                XCTAssertNil(browser.pairedViewer, "the Browser-only listing signal does not create a Viewer")
            }
        }
        let generations = [a.folderRequestGeneration, b.folderRequestGeneration]
        store.showHiddenFiles.wrappedValue = false
        XCTAssertEqual([a.folderRequestGeneration, b.folderRequestGeneration], generations,
                       "writing the unchanged policy must not start another listing")
    }

    /// The sidebar's Locations hold exactly the owned folders as volume roots
    /// (so the reveal lists only them, never Home or "/"). Returns the first.
    @MainActor
    private func ownFoldersAsRoots(_ tree: FolderTreeViewController, _ folders: [URL]) -> FolderTreeNode {
        let volumes = folders.enumerated().map {
            SidebarVolume(url: $1, name: "Owned \($0)", kind: .external, isEjectable: false)
        }
        tree.dataSource.rebuildRoots(favorites: [], volumes: volumes)
        tree.reload()
        return tree.dataSource.locationsSection!.children.first { $0.kind == .volume }!
    }

    /// A row opened by the user's own hand (collapse first: the reveal may
    /// already have opened it, and only a real open is saved).
    @MainActor
    private func userOpen(_ outline: NSOutlineView, _ node: FolderTreeNode) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) }
        outline.expandItem(node)
    }

    @MainActor
    private func ownedHiddenSidebar(_ browser: BrowserWindowController, folder: URL) -> FolderTreeNode {
        let tree = browser.treeControllerForTesting
        // A Favorite at the same folder must not take the selection.
        let root = ownFoldersAsRoots(tree, [folder])
        tree.dataSource.rebuildRoots(favorites: [SidebarFavoriteRow(url: folder, isMissing: false)],
                                     volumes: [SidebarVolume(url: folder, name: "Owned 0", kind: .external, isEjectable: false)])
        tree.reload()
        return tree.dataSource.locationsSection!.children.first { $0.kind == .volume } ?? root
    }

    @MainActor
    func testShowHiddenAndBothResetsRefreshLoadedSidebarWithoutWalkingCollapsedFolders() async throws {
        let fixture = try hiddenPolicyFixture()
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: fixture.folder)
        defer { browser.close() }
        let root = ownedHiddenSidebar(browser, folder: fixture.folder)
        let tree = browser.treeControllerForTesting, outline = tree.outlineViewForTesting
        var listed: [URL] = [], paints = 0
        tree.dataSource.didListFolder = { listed.append($0.standardizedFileURL) }
        browser.onFolderPaintedForTesting = { paints += 1 }
        try await waitForResetState { browser.contentController.visibleItems.map(\.url) == [fixture.visible] }
        await tree.selectTask?.value
        try selectHiddenPolicyControl(fixture.visible, browser: browser)
        outline.expandItem(root); await tree.loadTask?.value
        let branchURL = fixture.folder.appendingPathComponent("VisibleBranch", isDirectory: true).standardizedFileURL
        let branch = try XCTUnwrap(root.children.first { $0.url?.standardizedFileURL == branchURL })
        outline.expandItem(branch); await tree.loadTask?.value
        XCTAssertTrue(outline.isItemExpanded(root)); XCTAssertTrue(outline.isItemExpanded(branch))
        XCTAssertEqual(branch.children.map(\.title), ["Nested"])
        let store = PreferencesStore()
        func ready(_ hidden: Bool) -> Bool {
            let expected: Set<String> = hidden ? [".HiddenFolder", "Collapsed", "VisibleBranch"] : ["Collapsed", "VisibleBranch"]
            guard root.childrenLoaded, Set(root.children.map(\.title)) == expected,
                  let currentBranch = root.children.first(where: { $0.url?.standardizedFileURL == branchURL }),
                  currentBranch.childrenLoaded else { return false }
            return outline.isItemExpanded(root) && outline.isItemExpanded(currentBranch)
                && currentBranch.children.map(\.title) == ["Nested"]
                && Set(browser.contentController.visibleItems.map(\.url)) == Set(hidden ? [fixture.visible, fixture.hidden] : [fixture.visible])
        }
        for reset in ["binding", "general", "all"] {
            store.showHiddenFiles.wrappedValue = true
            try await waitForResetState { ready(true) }
            XCTAssertTrue(tree.dataSource.showHiddenFiles)
            XCTAssertEqual(browser.currentFolder, fixture.folder)
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [fixture.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, fixture.visible)
            if reset == "binding" { store.showHiddenFiles.wrappedValue = false }
            else if reset == "general" { store.notifyAndMutate { PreferencesTab.general.resetToDefaults() } }
            else { AdvancedTab.resetAllPreferences(using: store) }
            try await waitForResetState { ready(false) }
            XCTAssertFalse(tree.dataSource.showHiddenFiles)
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [fixture.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, fixture.visible)
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url, fixture.folder)
        }
        let generation = root.loadGeneration, reads = listed, paint = paints
        store.pairRAW.wrappedValue = false
        try await waitForResetState { paints > paint }
        XCTAssertEqual(root.loadGeneration, generation, "a pair-only signal must not invalidate the sidebar")
        XCTAssertEqual(listed, reads)
        XCTAssertTrue(ready(false))
        let allowed: Set<URL> = [fixture.folder, branchURL]
        XCTAssertTrue(Set(listed).isSubset(of: allowed), "no collapsed child or unowned Home/volume may be enumerated")
        XCTAssertFalse(listed.contains(fixture.folder.appendingPathComponent("Collapsed", isDirectory: true).standardizedFileURL))

        // An explicit open hidden folder stays current when its siblings become hidden.
        store.showHiddenFiles.wrappedValue = true
        try await waitForResetState { ready(true) }
        let hiddenFolder = fixture.folder.appendingPathComponent(".HiddenFolder", isDirectory: true).standardizedFileURL
        let beforeNavigation = paints
        browser.navigate(to: hiddenFolder)
        try await waitForResetState { paints > beforeNavigation && browser.currentFolder == hiddenFolder }
        await tree.selectTask?.value
        let beforeOff = paints
        store.showHiddenFiles.wrappedValue = false
        try await waitForResetState { paints > beforeOff && !tree.dataSource.showHiddenFiles }
        await tree.selectTask?.value
        XCTAssertEqual(browser.currentFolder, hiddenFolder)
        XCTAssertEqual(browser.window?.representedURL, hiddenFolder)
        XCTAssertEqual(tree.dataSource.currentFolder, hiddenFolder)
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
        XCTAssertEqual(selected.url, hiddenFolder)
        XCTAssertTrue(selected.isPathRow, "the hidden folder stays on the path as a 50 % row")
        XCTAssertTrue(selected.parent === root, "the selected row's parent chain reaches the tree root")
        XCTAssertEqual(selected.kind, .folder)
    }

    private actor SidebarFirstPaintGate {
        let visible: BrowserItem, hidden: BrowserItem
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isWaiting: Bool { !waiters.isEmpty }

        init(visible: BrowserItem, hidden: BrowserItem) {
            self.visible = visible; self.hidden = hidden
        }
        func arm() { held = true }
        func open() {
            held = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func scan(_ showHidden: Bool) async -> [BrowserItem] {
            if held { await withCheckedContinuation { waiters.append($0) } }
            return showHidden ? [visible, hidden] : [visible]
        }
    }

    @MainActor
    private func requireSidebarState(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let ready = await condition()
        _ = try XCTUnwrap(ready ? true : nil, message)
    }

    @MainActor
    func testLoadedCurrentFolderExpansionsSurviveHiddenPolicyFirstPaintAndPersistUserCollapse() async throws {
        let fixture = try hiddenPolicyFixture()
        // Enough owned leaf rows for a real scroll offset, without enumerating them.
        for index in 0..<60 {
            try FileManager.default.createDirectory(
                at: fixture.folder.appendingPathComponent(String(format: "Row%02d", index), isDirectory: true),
                withIntermediateDirectories: false)
        }
        let listing = SidebarFirstPaintGate(visible: try BrowserItem.make(from: fixture.visible),
                                            hidden: try BrowserItem.make(from: fixture.hidden))
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: fixture.folder,
            folderEnumerator: { _, hidden in await listing.scan(hidden) })
        defer { browser.close() }
        let tree = browser.treeControllerForTesting, outline = tree.outlineViewForTesting
        // The owned folder is the one tree root: the reveal lists only it.
        _ = ownFoldersAsRoots(tree, [fixture.folder])
        var reads: [URL] = [], paints = 0
        tree.dataSource.didListFolder = { reads.append($0.standardizedFileURL) }
        browser.onFolderPaintedForTesting = { paints += 1 }
        let branchURL = fixture.folder.appendingPathComponent("VisibleBranch", isDirectory: true).standardizedFileURL
        let collapsedURL = fixture.folder.appendingPathComponent("Collapsed", isDirectory: true).standardizedFileURL
        let expansionKey = "shrike.browser.tree.expanded"
        func root() throws -> FolderTreeNode {
            try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        }
        func child(_ url: URL, of parent: FolderTreeNode) throws -> FolderTreeNode {
            try XCTUnwrap(parent.children.first { $0.url?.standardizedFileURL == url })
        }
        func loadedOpenState(_ collapsedOpen: Bool, hidden: Bool) -> Bool {
            guard let current = tree.dataSource.locationsSection?.children.first(where: { $0.kind == .volume }),
                  current.childrenLoaded, outline.isItemExpanded(current),
                  let branch = current.children.first(where: { $0.url?.standardizedFileURL == branchURL }),
                  branch.childrenLoaded, outline.isItemExpanded(branch),
                  let collapsed = current.children.first(where: { $0.url?.standardizedFileURL == collapsedURL }),
                  outline.isItemExpanded(collapsed) == collapsedOpen else { return false }
            let expected = Set((0..<60).map { String(format: "Row%02d", $0) }
                + ["VisibleBranch", "Collapsed"] + (hidden ? [".HiddenFolder"] : []))
            return Set(current.children.map(\.title)) == expected
                && branch.children.map(\.title) == ["Nested"]
                && (!collapsedOpen || (collapsed.childrenLoaded && collapsed.children.map(\.title) == ["DoNotWalk"]))
        }
        func finishSidebarCallbacks() async {
            // Public task ownership, not an instrumentation-only operations registry.
            // A completed parent can have scheduled a restored child's task.
            while let latest = tree.loadTask {
                await latest.value
                if tree.loadTask == latest { return }
            }
        }
        func assertPhoto(_ hidden: Bool) throws {
            XCTAssertEqual(browser.currentFolder, fixture.folder)
            XCTAssertEqual(browser.window?.representedURL, fixture.folder)
            XCTAssertEqual(tree.dataSource.currentFolder, fixture.folder)
            XCTAssertEqual(Set(browser.contentController.visibleItems.map(\.url)),
                           Set(hidden ? [fixture.visible, fixture.hidden] : [fixture.visible]))
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [fixture.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, fixture.visible)
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url?.standardizedFileURL, fixture.folder)
        }
        do {
            try await requireSidebarState("initial real Browser paint") {
                paints == 1 && browser.contentController.visibleItems.map(\.url) == [fixture.visible]
                    && !browser.contentController.isHydratingMarks
            }
            await tree.selectTask?.value
            try selectHiddenPolicyControl(fixture.visible, browser: browser)
            let initial = try root()
            XCTAssertEqual(initial.parent?.section, .locations)
            XCTAssertFalse(tree.dataSource.roots.contains { $0.section == .favorites })
            userOpen(outline, initial); await finishSidebarCallbacks()
            userOpen(outline, try child(branchURL, of: initial)); await finishSidebarCallbacks()
            userOpen(outline, try child(collapsedURL, of: initial)); await finishSidebarCallbacks()
            XCTAssertTrue(loadedOpenState(true, hidden: false))
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(outline.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 8))
            scroll.reflectScrolledClipView(scroll.contentView)
            let origin = scroll.contentView.bounds.origin
            XCTAssertGreaterThan(origin.y, 0, "positive control: preserve an actual scroll offset")
            let store = PreferencesStore()
            for showHidden in [true, false] {
                let collapsedOpen = showHidden
                let beforePaint = paints, beforeGeneration = browser.folderRequestGeneration
                let beforeClosedReads = reads.filter { $0 == collapsedURL }.count
                await listing.arm()
                store.showHiddenFiles.wrappedValue = showHidden
                try await requireSidebarState("sidebar restoration finishes before held Browser first paint") {
                    let waiting = await listing.isWaiting
                    return loadedOpenState(collapsedOpen, hidden: showHidden) && waiting
                }
                await finishSidebarCallbacks()
                XCTAssertEqual(paints, beforePaint, "the Browser listing is still held after all sidebar callbacks")
                let saved = Set(ShrikeDefaults.store.stringArray(forKey: expansionKey) ?? [])
                XCTAssertTrue(saved.contains(fixture.folder.path))
                XCTAssertTrue(saved.contains(branchURL.path))
                XCTAssertEqual(saved.contains(collapsedURL.path), collapsedOpen)
                await listing.open()
                await browser.listingTask?.value
                await tree.selectTask?.value
                try await requireSidebarState("normal first paint preserves already loaded/open paths") {
                    paints == beforePaint + 1 && loadedOpenState(collapsedOpen, hidden: showHidden)
                        && !browser.contentController.isHydratingMarks
                }
                await finishSidebarCallbacks()
                XCTAssertGreaterThan(browser.folderRequestGeneration, beforeGeneration)
                XCTAssertEqual(scroll.contentView.bounds.origin, origin)
                try assertPhoto(showHidden)
                if showHidden {
                    outline.collapseItem(try child(collapsedURL, of: root()))
                    XCTAssertTrue(loadedOpenState(false, hidden: true), "actual user collapse remains active outside reload")
                    let persisted = Set(ShrikeDefaults.store.stringArray(forKey: expansionKey) ?? [])
                    XCTAssertFalse(persisted.contains(collapsedURL.path), "real collapse must update saved expansion paths")
                    XCTAssertTrue(persisted.contains(fixture.folder.path))
                    XCTAssertTrue(persisted.contains(branchURL.path))
                } else {
                    XCTAssertEqual(reads.filter { $0 == collapsedURL }.count, beforeClosedReads,
                                   "restoring root and VisibleBranch must not enumerate the closed Collapsed branch")
                }
            }
            XCTAssertTrue(Set(reads).isSubset(of: [fixture.folder, branchURL, collapsedURL]),
                          "no leaf row, hidden folder, descendant or unowned filesystem root is read")
        } catch {
            await listing.open()
            await browser.listingTask?.value
            await tree.selectTask?.value
            await finishSidebarCallbacks()
            throw error
        }
    }

    @MainActor
    func testHiddenTopologyKeepsVisibleRowAndPixelOffsetThroughGeneralAndAllReset() async throws {
        let fixture = try hiddenPolicyFixture()
        for name in [".SecondHiddenFolder"] + (0..<60).map({ String(format: "Row%02d", $0) }) {
            try FileManager.default.createDirectory(at: fixture.folder.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let listing = SidebarFirstPaintGate(visible: try BrowserItem.make(from: fixture.visible),
                                            hidden: try BrowserItem.make(from: fixture.hidden))
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: fixture.folder,
            folderEnumerator: { _, hidden in await listing.scan(hidden) })
        defer { browser.close() }
        let tree = browser.treeControllerForTesting, outline = tree.outlineViewForTesting
        _ = ownFoldersAsRoots(tree, [fixture.folder])
        let branchURL = fixture.folder.appendingPathComponent("VisibleBranch").standardizedFileURL
        let closedURL = fixture.folder.appendingPathComponent("Collapsed").standardizedFileURL
        var reads: [URL] = []
        tree.dataSource.didListFolder = { reads.append($0.standardizedFileURL) }
        func root() throws -> FolderTreeNode {
            try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        }
        func finishCallbacks() async {
            while let task = tree.loadTask { await task.value; if tree.loadTask == task { return } }
        }
        func restored(_ hidden: Bool) -> Bool {
            guard let current = tree.dataSource.locationsSection?.children.first(where: { $0.kind == .volume }),
                  current.childrenLoaded, outline.isItemExpanded(current),
                  let branch = current.children.first(where: { $0.url?.standardizedFileURL == branchURL }),
                  branch.childrenLoaded, outline.isItemExpanded(branch) else { return false }
            return current.children.contains { $0.title == ".SecondHiddenFolder" } == hidden
        }
        func visibleContext() throws -> (String, CGFloat) {
            let row = outline.rows(in: outline.visibleRect).location
            let node = try XCTUnwrap(outline.item(atRow: row) as? FolderTreeNode)
            return (node.title, outline.rect(ofRow: row).minY - outline.visibleRect.minY)
        }
        func assertContext(_ offset: CGFloat) throws {
            let context = try visibleContext()
            XCTAssertEqual(context.0, "Row25"); XCTAssertEqual(context.1, offset, accuracy: 0.5)
            XCTAssertEqual(browser.currentFolder, fixture.folder)
            XCTAssertEqual(browser.window?.representedURL, fixture.folder)
            XCTAssertEqual(tree.dataSource.currentFolder, fixture.folder)
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [fixture.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, fixture.visible)
            let closed = try XCTUnwrap(try root().children.first { $0.url?.standardizedFileURL == closedURL })
            XCTAssertFalse(outline.isItemExpanded(closed)); XCTAssertFalse(closed.childrenLoaded)
        }
        do {
            try await requireSidebarState("initial owned Browser paint") {
                browser.contentController.visibleItems.map(\.url) == [fixture.visible]
                    && !browser.contentController.isHydratingMarks
            }
            await tree.selectTask?.value
            try selectHiddenPolicyControl(fixture.visible, browser: browser)
            userOpen(outline, try root()); await finishCallbacks()
            let branch = try XCTUnwrap(try root().children.first { $0.url?.standardizedFileURL == branchURL })
            userOpen(outline, branch); await finishCallbacks()
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            let target = try XCTUnwrap(try root().children.first { $0.title == "Row25" })
            let scroll = try XCTUnwrap(outline.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: outline.row(forItem: target)).minY + 5))
            scroll.reflectScrolledClipView(scroll.contentView)
            let baseline = try visibleContext(), originalY = scroll.contentView.bounds.minY
            XCTAssertEqual(baseline.0, "Row25")
            let store = PreferencesStore()
            for resetAll in [false, true] {
                for hidden in [true, false] {
                    await listing.arm()
                    if hidden { store.showHiddenFiles.wrappedValue = true }
                    else if resetAll { AdvancedTab.resetAllPreferences(using: store) }
                    else { store.notifyAndMutate { PreferencesTab.general.resetToDefaults() } }
                    try await requireSidebarState("sidebar row topology settles while Browser first paint is held") {
                        let waiting = await listing.isWaiting
                        return waiting && restored(hidden)
                    }
                    await finishCallbacks()
                    let beforePaint = try visibleContext()
                    XCTAssertEqual(beforePaint.0, "Row25")
                    XCTAssertEqual(beforePaint.1, baseline.1, accuracy: 0.5)
                    if hidden { XCTAssertGreaterThan(scroll.contentView.bounds.minY, originalY) }
                    await listing.open(); await browser.listingTask?.value; await tree.selectTask?.value
                    try await requireSidebarState("same-folder first paint restores the same loaded context") {
                        restored(hidden) && !browser.contentController.isHydratingMarks
                    }
                    await finishCallbacks()
                    try assertContext(baseline.1)
                }
            }
            XCTAssertFalse(reads.contains(closedURL), "Viewport anchoring must never enumerate a closed branch")
            XCTAssertTrue(Set(reads).isSubset(of: [fixture.folder, branchURL]))
        } catch {
            await listing.open(); await browser.listingTask?.value; await tree.selectTask?.value
            await finishCallbacks()
            throw error
        }
    }

    @MainActor
    func testSameFolderFirstPaintKeepsLatestViewportAndLateReloadCannotMoveNewFolder() async throws {
        let a = try hiddenPolicyFixture(), b = try hiddenPolicyFixture()
        for index in 0..<60 {
            try FileManager.default.createDirectory(
                at: a.folder.appendingPathComponent(String(format: "Row%02d", index), isDirectory: true),
                withIntermediateDirectories: false)
        }
        let listing = SidebarFirstPaintGate(visible: try BrowserItem.make(from: a.visible),
                                            hidden: try BrowserItem.make(from: a.hidden))
        let bItem = try BrowserItem.make(from: b.visible)
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: a.folder,
            folderEnumerator: { folder, hidden in
                if folder == a.folder { return await listing.scan(hidden) }
                return [bItem]
            })
        defer { browser.close() }
        let tree = browser.treeControllerForTesting, outline = tree.outlineViewForTesting
        _ = ownFoldersAsRoots(tree, [a.folder, b.folder])
        var paints = 0
        var obsoleteListing: Task<Void, Never>?
        browser.onFolderPaintedForTesting = { paints += 1 }
        func root() throws -> FolderTreeNode {
            try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        }
        func aLoadedOpen(_ hidden: Bool) -> Bool {
            guard let current = tree.dataSource.locationsSection?.children.first(where: { $0.kind == .volume }),
                  current.url?.standardizedFileURL == a.folder, current.childrenLoaded,
                  outline.isItemExpanded(current) else { return false }
            return current.children.contains { $0.title == ".HiddenFolder" } == hidden
        }
        do {
            try await requireSidebarState("initial A paint") {
                paints == 1 && browser.contentController.visibleItems.map(\.url) == [a.visible]
                    && !browser.contentController.isHydratingMarks
            }
            await tree.selectTask?.value
            try selectHiddenPolicyControl(a.visible, browser: browser)
            userOpen(outline, try root()); await tree.loadTask?.value
            XCTAssertTrue(aLoadedOpen(false))
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(outline.enclosingScrollView)
            // Geometry coverage: direct clip changes, not a claim of physical scroll input.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 8))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 8)
            let store = PreferencesStore(), beforePaint = paints
            await listing.arm()
            store.showHiddenFiles.wrappedValue = true
            try await requireSidebarState("A sidebar loads before held first paint") {
                let waiting = await listing.isWaiting
                return waiting && aLoadedOpen(true)
            }
            await tree.loadTask?.value
            XCTAssertEqual(paints, beforePaint)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 36))
            scroll.reflectScrolledClipView(scroll.contentView)
            let latest = scroll.contentView.bounds.origin
            XCTAssertEqual(latest.y, 36, "positive control: a newer valid viewport replaces the pre-policy y=8")
            await listing.open()
            await browser.listingTask?.value
            await tree.selectTask?.value
            try await requireSidebarState("same-folder first paint and sidebar replacement finish") {
                paints == beforePaint + 1 && aLoadedOpen(true)
                    && !browser.contentController.isHydratingMarks
            }
            await tree.loadTask?.value
            XCTAssertEqual(scroll.contentView.bounds.origin, latest,
                           "first paint must preserve the current viewport rather than replay the old policy origin")
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [a.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, a.visible)

            await listing.arm()
            store.showHiddenFiles.wrappedValue = false
            try await requireSidebarState("a second A reload is actually held") { await listing.isWaiting }
            let obsoleteA = try XCTUnwrap(browser.listingTask)
            obsoleteListing = obsoleteA
            browser.navigate(to: b.folder)
            await browser.listingTask?.value
            await tree.selectTask?.value
            try await requireSidebarState("B navigation paints and selects its own photo") {
                browser.currentFolder == b.folder && browser.window?.representedURL == b.folder
                    && browser.contentController.selectedItems.map(\.url) == [b.visible]
                    && !browser.contentController.isHydratingMarks
            }
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url?.standardizedFileURL, b.folder)
            XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)),
                          "new-folder navigation still reveals its actual selected row")
            let bOrigin = scroll.contentView.bounds.origin
            XCTAssertNotEqual(bOrigin, latest, "the short B tree uses its own navigation viewport")
            let bAnchor = browser.contentController.selectionAnchorURL
            XCTAssertNil(bAnchor, "automatic first-photo selection in Grid has no explicit clicked range anchor")
            await listing.open()
            await obsoleteA.value
            await tree.loadTask?.value
            XCTAssertEqual(browser.currentFolder, b.folder)
            XCTAssertEqual(browser.window?.representedURL, b.folder)
            XCTAssertEqual(tree.dataSource.currentFolder, b.folder)
            XCTAssertEqual(browser.contentController.visibleItems.map(\.url), [b.visible])
            XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [b.visible])
            XCTAssertEqual(browser.contentController.selectionAnchorURL, bAnchor,
                           "late A completion must preserve B's established automatic-selection anchor state")
            let finalSelected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(finalSelected.url?.standardizedFileURL, b.folder)
            XCTAssertEqual(scroll.contentView.bounds.origin, bOrigin, "late A completion cannot replay A's viewport over B")
            XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)))
        } catch {
            await listing.open()
            await obsoleteListing?.value
            await browser.listingTask?.value
            await tree.selectTask?.value
            await tree.loadTask?.value
            throw error
        }
    }

}

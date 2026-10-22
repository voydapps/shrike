//
//  Fixes027dTests.swift
//  ShrikeUITests
//
//  The 0.2.7 on-screen check's findings:
//  lazy menu hints, the broken-photo card wrap, Return from a panel field,
//  a stale viewer inspector, context-menu keys, filmstrip VoiceOver labels,
//  Share in the Browser menu, a stale list Dimensions, edit field labels.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class Fixes027dTests: XCTestCase {

    private var dir: URL!
    private var savedPreset: ShortcutPreset!
    private var savedFilmstrip = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-fix027d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedPreset = Prefs.shortcutPreset
        Prefs.shortcutPreset = .macNative
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        Prefs.filmstripVisibleInWindowed = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.shortcutPreset = savedPreset
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
    }

    // MARK: Helpers

    private func services() throws -> ShrikeServices {
        let support = dir.appendingPathComponent(".support", isDirectory: true)
        let thumbs = try ThumbnailCache(diskURL: support.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: support.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 400, height: Int = 300) throws -> URL {
        let folder = dir.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    private func bar() -> ShrikeMainMenu {
        ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
    }

    private func menu(_ bar: ShrikeMainMenu, _ title: String) throws -> NSMenu {
        try XCTUnwrap(bar.menu.items.first { $0.submenu?.title == title }?.submenu)
    }

    // MARK: 1. Hints are lazy

    func testHintsAreNotDrawnAtLaunchButWhenAMenuOpens() throws {
        let bar = bar()
        let image = try menu(bar, "Image")
        let flag = try XCTUnwrap(bar.items(for: .toggleFlag).first)
        XCTAssertNil(flag.badge, "nothing is drawn while the bar is built")
        bar.menuNeedsUpdate(image)
        XCTAssertEqual(flag.badge?.stringValue, "Q")
        let rate3 = try XCTUnwrap(bar.items(for: .rate3).first)
        XCTAssertEqual(rate3.badge?.stringValue, "3")
    }

    /// Spec 25 §13.1 (decided 2026-10-12): an item that has a menu key shows only that
    /// key. Actual Size has ⌘1 and Edit Image ⌘E, so neither gets a bare-key hint.
    func testItemsWithAMenuKeyGetNoHint() throws {
        let bar = bar()
        bar.applyKeyHints()
        for command in [ShrikeCommand.actualSize, .editImage] {
            for item in bar.items(for: command) {
                XCTAssertNil(item.badge, "\(command) has a menu key and no hint")
            }
        }
    }

    // MARK: 5. Context-menu F2

    func testBrowserContextMenuRenameShowsPlainF2() throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let menu = try XCTUnwrap(browser.contentController.collectionViewForTesting.menu)
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" })
        XCTAssertEqual(rename.keyEquivalent, SpecialKey.f2)
        XCTAssertTrue(rename.keyEquivalentModifierMask.isEmpty, "F2, not ⌘F2")
    }

    func testViewerContextMenuRenameShowsF2() throws {
        let url = try writeJPEG("a.jpg")
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: try services())
        defer { window.close() }
        let contextMenu = ViewerContextMenu(window: window)
        contextMenu.prepareForTesting()
        let rename = try XCTUnwrap(contextMenu.menu.items.first { $0.representedObject as? String == ShrikeCommand.rename.rawValue })
        XCTAssertEqual(rename.keyEquivalent, SpecialKey.f2)
        XCTAssertTrue(rename.keyEquivalentModifierMask.isEmpty)
    }

    // MARK: 2. Broken-photo card text wraps

    func testErrorCardTextWrapsOntoTwoLinesAtTheCardWidth() {
        let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.layoutSubtreeIfNeeded()
        let font = overlay.bodyForTesting.font ?? .systemFont(ofSize: 12)
        let line = ceil(font.boundingRectForFont.height)
        // Spec 27 P3-3: the card is 420 pt wide, so the copy may fit on one line; it must never be clipped.
        XCTAssertGreaterThanOrEqual(overlay.bodyNeededHeightForTesting, line * 0.9, "the text needs at least a line")
        XCTAssertGreaterThanOrEqual(overlay.bodyFrameForTesting.height, overlay.bodyNeededHeightForTesting, "and the label has room for all of it")
        XCTAssertEqual(overlay.bodyForTesting.lineBreakMode, .byWordWrapping)
        // Drawn: the label alone holds two separate bands of ink rows.
        let label = overlay.bodyForTesting
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return XCTFail("no bitmap") }
        label.cacheDisplay(in: label.bounds, to: rep)
        var previous = false
        var bands = 0
        for y in 0..<rep.pixelsHigh {
            var ink = false
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { ink = true; break }
            if ink && !previous { bands += 1 }
            previous = ink
        }
        XCTAssertGreaterThanOrEqual(bands, 1, "the text is drawn")
    }

    // MARK: 3. Return from a panel field reaches Done

    private final class DoneCounter: NSObject {
        var count = 0
        @objc func done(_ sender: Any?) { count += 1 }
    }

    private func keyDown(_ chars: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testReturnInAPanelFieldCommitsThenTheNextReturnIsDone() async throws {
        let panel = ResizePanel()
        panel.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        panel.sourcePixelSize = CGSize(width: 1500, height: 1000)
        let counter = DoneCounter()
        let done = NSButton(title: "Done", target: counter, action: #selector(DoneCounter.done(_:)))
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 0, y: 500, width: 80, height: 24)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 540), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // ARC owns the window: the default isReleasedWhenClosed releases it a second time, which
        // crashes in a later test (autorelease of the close animation) when a screen is on.
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView?.addSubview(panel)
        window.contentView?.addSubview(done)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var specs = 0
        panel.onSpecChanged = { _ in specs += 1 }

        let field = panel._widthField
        XCTAssertTrue(window.makeFirstResponder(field))
        field.currentEditor()?.string = "3000"
        window.sendEvent(keyDown("\r", code: 36, in: window))
        XCTAssertEqual(specs, 1, "the first Return commits the field")
        XCTAssertEqual(panel._heightField.stringValue, "2000")
        XCTAssertEqual(counter.count, 0, "and is not Done")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(field.currentEditor(), "the field gave up focus")
        window.sendEvent(keyDown("\r", code: 36, in: window))
        XCTAssertEqual(counter.count, 1, "the next Return is Done")
    }

    // MARK: 10. Edit fields are exposed to VoiceOver

    /// What VoiceOver sees: the panel's accessibility children (text fields come as their
    /// cells), with each child's role and label.
    private func axChildren(_ view: NSView) -> [(role: String, label: String)] {
        (view.accessibilityChildren() ?? []).map { child in
            if let cell = child as? NSCell { return (cell.accessibilityRole()?.rawValue ?? "", cell.accessibilityLabel() ?? "") }
            if let v = child as? NSView { return (v.accessibilityRole()?.rawValue ?? "", v.accessibilityLabel() ?? "") }
            return ("", "")
        }
    }

    func testResizeAndCropFieldsAreExposedWithLabels() {
        let resize = ResizePanel()
        resize.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        resize.layoutSubtreeIfNeeded()
        let resizeFields = axChildren(resize).filter { $0.role == "AXTextField" }.map(\.label)
        XCTAssertEqual(resizeFields, ["Resize width, pixels", "Resize height, pixels", "Resize percent"])
        let crop = CropPanel()
        crop.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        crop.layoutSubtreeIfNeeded()
        let cropFields = axChildren(crop).filter { $0.role == "AXTextField" }.map(\.label)
        XCTAssertEqual(cropFields, ["Crop width, pixels", "Crop height, pixels"])
    }

    // MARK: 4. Stale inspector marks after a Browser open

    func testInspectorShowsTheNewPhotosMarksAfterAnOpenFromTheBrowser() async throws {
        let urls = try (0..<3).map { try writeJPEG("p\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) }, startIndex: 1,
                                  services: try services())
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        let root = window.contentRootForTesting
        let ready1 = await waitUntil { window.displayedItem?.listIndex == 1 }
        XCTAssertTrue(ready1)
        window.rateDisplayed(3)
        window.toggleFlagDisplayed()
        let ready2 = await waitUntil { root.inspectorPanel.viewModel.marks.rating == 3 && root.inspectorPanel.viewModel.marks.flagged }
        XCTAssertTrue(ready2)
        // The Browser opens photo 3 in the same viewer (its list is read again).
        window.showFromBrowser(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 2)
        let ready3 = await waitUntil { window.displayedItem?.listIndex == 2 }
        XCTAssertTrue(ready3)
        _ = await waitUntil(2) { false }   // let the record read land
        XCTAssertEqual(window.displayedItem?.group.primary.lastPathComponent, "p2.jpg")
        XCTAssertEqual(root.inspectorPanel.viewModel.marks.rating, 0, "photo 3 has no rating")
        XCTAssertFalse(root.inspectorPanel.viewModel.marks.flagged)
    }

    // MARK: 6. Filmstrip cell VoiceOver label

    func testFilmstripCellsAreLabelledWithNameStarsAndFlag() async throws {
        let urls = try (0..<3).map { try writeJPEG("p\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) }, startIndex: 0,
                                  services: try services())
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let root = window.contentRootForTesting
        let ready4 = await waitUntil { window.displayedItem?.listIndex == 0 && root.filmstripMarksForTesting(1) != nil }
        XCTAssertTrue(ready4)
        let plain = try XCTUnwrap(root.filmstripCellViewForTesting(1))
        XCTAssertTrue(plain.isAccessibilityElement())
        XCTAssertEqual(plain.accessibilityLabel(), "p1.jpg")
        XCTAssertEqual((plain.accessibilityChildren() ?? []).count, 0, "one element per cell")
        window.rateDisplayed(2)
        window.toggleFlagDisplayed()
        // The rating and the flag are two separate writes; wait for both.
        let ready5 = await waitUntil {
            root.filmstripMarksForTesting(0)?.rating == 2 && root.filmstripMarksForTesting(0)?.flagged == true
        }
        XCTAssertTrue(ready5)
        let marked = try XCTUnwrap(root.filmstripCellViewForTesting(0))
        XCTAssertEqual(marked.accessibilityLabel(), "p0.jpg, 2 stars, flagged")
    }

    // MARK: 8. Share in the Browser menu

    func testBrowserContextMenuShareIsEnabledWithOnePhotoSelected() async throws {
        let a = try writeJPEG("a.jpg")
        let folder = a.deletingLastPathComponent()
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: folder)
        defer { browser.close() }
        let content = browser.contentController
        let ready6 = await waitUntil { content.visibleItems.count == 1 }
        XCTAssertTrue(ready6)
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        let share = try XCTUnwrap(menu.items.first { $0.representedObject as? String == ShrikeCommand.share.rawValue })
        XCTAssertFalse(share.isEnabled, "nothing is selected yet")
        content.select(urls: [a])
        content.menuNeedsUpdate(menu)
        XCTAssertTrue(share.isEnabled, "one JPEG selected")
        XCTAssertNotNil(share.submenu)
    }

    // MARK: 9a. List Dimensions prefers the freshest size

    func testListDimensionsIgnoresAListingSizeAfterTheFileChanged() async throws {
        let a = try writeJPEG("a.jpg", width: 400, height: 300)
        let folder = a.deletingLastPathComponent()
        let browser = BrowserWindowController(services: try services(), initialFolder: folder)
        defer { browser.close() }
        let content = browser.contentController
        let ready7 = await waitUntil { content.visibleItems.count == 1 }
        XCTAssertTrue(ready7)
        content.setMode(.list)
        await content.waitForListDimensions()
        let item = try XCTUnwrap(content.visibleItems.first)
        XCTAssertEqual(content.listDimensionsText(item), "400 × 300")
        // The file changed on disk with the same date: the listing's size (if any) is not trusted.
        let stale = BrowserItem(url: item.url, displayName: item.displayName, fileSize: item.fileSize,
                                modificationDate: item.modificationDate, utType: item.utType,
                                pixelWidth: 111, pixelHeight: 222)
        XCTAssertEqual(content.listDimensionsText(stale), "400 × 300", "the header read wins over the listing")
        content.forgetFileSizes(for: [a])
        XCTAssertEqual(content.listDimensionsText(stale), "—", "after a change the old listing size is not shown")
    }
}

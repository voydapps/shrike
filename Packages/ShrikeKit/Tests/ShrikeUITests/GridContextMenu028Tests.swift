//
//  GridContextMenu028Tests.swift
//  ShrikeUITests
//
//  Spec 28 §12 (L-13): the grid's right-click menu. The model is a pure
//  function of the selection; the NSMenu is built from it; Edit Photo from
//  the Browser opens a viewer and enters edit mode once the photo is shown.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

final class GridContextMenuModelTests: XCTestCase {

    private func titles(_ state: GridMenuState) -> [String] {
        GridContextMenuModel.rows(for: state).map { $0.isSeparator ? "—" : $0.title }
    }

    private func enabled(_ state: GridMenuState) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: GridContextMenuModel.rows(for: state)
            .filter { !$0.isSeparator }.map { ($0.title, $0.enabled) })
    }

    private let list = ["Open", "Open With", "Open in External Editor", "Reveal in Finder", "Share",
                        "Slideshow…", "Batch…", "Compare", "—",
                        "Rotate Left", "Rotate Right", "Edit Photo", "—",
                        "Rating", "Flag", "Tags…", "—",
                        "Copy to Folder", "Move to Folder", "Rename…"]
    private let tail = ["—", "Copy", "Copy Path", "—", "Move to Trash"]

    func testOnePhotoHasTheListOfSpec28Section12() {
        let state = GridMenuState(selectedCount: 1, visibleCount: 5)
        XCTAssertEqual(titles(state), list + tail)
        XCTAssertTrue(enabled(state).values.allSatisfy { $0 }, "one ordinary photo: every row works")
        let rows = GridContextMenuModel.rows(for: state)
        XCTAssertEqual(rows.filter(\.hasSubmenu).map(\.title),
                       ["Open With", "Open in External Editor", "Share", "Rating", "Copy to Folder", "Move to Folder"])
        XCTAssertEqual(rows.first { $0.id == .editPhoto }?.command, .editImage)
    }

    func testSeveralPhotosTurnRenameAndEditPhotoOff() {
        let state = GridMenuState(selectedCount: 3, visibleCount: 5)
        XCTAssertEqual(titles(state), list + tail)
        let on = enabled(state)
        XCTAssertEqual(on["Rename…"], false)
        XCTAssertEqual(on["Edit Photo"], false)
        XCTAssertEqual(on["Open"], true)
        XCTAssertEqual(on["Move to Trash"], true)
        XCTAssertEqual(on["Compare"], true)
    }

    func testRAWOnlyPhotoTurnsEditPhotoOffOnly() {
        let state = GridMenuState(selectedCount: 1, visibleCount: 5, rawOnly: true)
        let on = enabled(state)
        XCTAssertEqual(on["Edit Photo"], false)
        XCTAssertEqual(on.filter { !$0.value }.count, 1)
    }

    func testUnreadablePhotoTurnsEditPhotoOffOnly() {
        let state = GridMenuState(selectedCount: 1, visibleCount: 5, unreadable: true)
        let on = enabled(state)
        XCTAssertEqual(on["Edit Photo"], false)
        XCTAssertEqual(on.filter { !$0.value }.count, 1)
    }

    func testRevertToOriginalShowsOnlyWithAKeptOriginalAfterRename() {
        var state = GridMenuState(selectedCount: 1, visibleCount: 5)
        XCTAssertFalse(titles(state).contains(ShrikeCommand.revertToOriginal.title))
        state.hasKeptOriginal = true
        let shown = titles(state)
        let at = try? XCTUnwrap(shown.firstIndex(of: ShrikeCommand.revertToOriginal.title))
        XCTAssertEqual(at, shown.firstIndex(of: "Rename…").map { $0 + 1 })
        XCTAssertEqual(shown, list + [ShrikeCommand.revertToOriginal.title] + tail)
        // Several photos: never offered.
        state.selectedCount = 2
        XCTAssertFalse(titles(state).contains(ShrikeCommand.revertToOriginal.title))
    }

    func testNothingSelectedKeepsOnlyTheFolderWideRows() {
        let state = GridMenuState(selectedCount: 0, visibleCount: 4)
        XCTAssertEqual(titles(state), list + tail)
        let on = enabled(state)
        XCTAssertEqual(on.filter(\.value).keys.sorted(), ["Batch…", "Slideshow…"])
        let empty = enabled(.nothing)
        XCTAssertTrue(empty.values.allSatisfy { !$0 }, "an empty folder: everything is grey")
    }

    func testCompareNeedsTwoPhotosInTheFolder() {
        XCTAssertEqual(enabled(GridMenuState(selectedCount: 1, visibleCount: 1))["Compare"], false)
        XCTAssertEqual(enabled(GridMenuState(selectedCount: 1, visibleCount: 2))["Compare"], true)
    }

    func testListingPlaceholderMeansUnreadable() {
        let ok = BrowserItem(url: URL(fileURLWithPath: "/a.jpg"), displayName: "a.jpg", fileSize: 10,
                             modificationDate: Date(timeIntervalSince1970: 100), utType: .jpeg)
        XCTAssertFalse(ok.isListingUnreadable)
        let bad = BrowserItem(url: URL(fileURLWithPath: "/b.jpg"), displayName: "b.jpg", fileSize: 0,
                              modificationDate: Date(timeIntervalSince1970: 0), utType: .jpeg)
        XCTAssertTrue(bad.isListingUnreadable)
    }
}

@MainActor
final class GridContextMenuWindowTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-gridmenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testGridMenuHasTheRowsOfTheModelInOrder() throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let menu = try XCTUnwrap(browser.contentController.collectionViewForTesting.menu)
        let shown = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        let model = GridContextMenuModel.rows(for: GridMenuState(selectedCount: 1, visibleCount: 2, hasKeptOriginal: true))
            .map { $0.isSeparator ? "—" : $0.title }
        XCTAssertEqual(shown, model)
    }

    func testMenuValidationFollowsTheModelForOneAndSeveralPhotos() async throws {
        let a = writeJPEG("a.jpg"), b = writeJPEG("b.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        await browser.listingTask?.value
        let content = browser.contentController
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        XCTAssertTrue(content.select(url: a))
        content.menuNeedsUpdate(menu)
        func check(_ label: String) {
            let state = content.gridMenuState
            for row in GridContextMenuModel.rows(for: state) where !row.isSeparator {
                guard let item = menu.items.first(where: { BrowserContentViewController.gridRowID(of: $0) == row.id }) else {
                    return XCTFail("\(label): no item for \(row.title)")
                }
                // Items with a command go to the window controller, the others to the grid.
                let result: Bool
                if item.action == ShrikeMainMenu.commandAction { result = browser.validateMenuItem(item) }
                else if item.action == nil { result = item.isEnabled }
                else { result = content.validateMenuItem(item) }
                if row.id == .share || row.id == .externalEditor { continue }   // refreshed by their own helpers
                XCTAssertEqual(result, row.enabled, "\(label): \(row.title)")
            }
        }
        check("one photo")
        XCTAssertTrue(browser.canPerform(.editImage))
        content.selectAll()
        XCTAssertEqual(content.selectedItems.count, 2)
        content.menuNeedsUpdate(menu)
        check("two photos")
        XCTAssertFalse(browser.canPerform(.editImage), "Edit Photo is off for several photos")
        _ = b
    }

    func testRevertRowHidesWithoutAKeptOriginal() async throws {
        let a = writeJPEG("a.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        await browser.listingTask?.value
        let content = browser.contentController
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        XCTAssertTrue(content.select(url: a))
        content.menuNeedsUpdate(menu)
        let revert = try XCTUnwrap(menu.items.first { $0.title == ShrikeCommand.revertToOriginal.title })
        XCTAssertTrue(revert.isHidden)
        content.revertAvailableProvider = { true }
        content.menuNeedsUpdate(menu)
        XCTAssertFalse(revert.isHidden)
    }

    func testOpenWithRowFillsItsSubmenuOnOpen() async throws {
        let a = writeJPEG("a.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        await browser.listingTask?.value
        let content = browser.contentController
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        XCTAssertTrue(content.select(url: a))
        let parent = try XCTUnwrap(menu.items.first { $0.title == "Open With" })
        let submenu = try XCTUnwrap(parent.submenu)
        content.menuNeedsUpdate(submenu)
        XCTAssertFalse(submenu.items.isEmpty)
    }

    /// Edit Photo from the Browser: a viewer opens and edit mode starts with no tool, after the
    /// photo is shown (the request waits for it instead of being refused as "still loading").
    func testEditPhotoFromTheBrowserEntersEditModeOnceThePhotoIsShown() async throws {
        let a = writeJPEG("a.jpg"), b = writeJPEG("b.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.pairedViewer?.close(); browser.close() }
        await browser.listingTask?.value
        XCTAssertTrue(browser.contentController.select(url: b))
        XCTAssertTrue(browser.canPerform(.editImage))
        browser.perform(.editImage)
        let viewer = try XCTUnwrap(browser.pairedViewer)
        // Not in edit mode yet in the same turn: the photo has not been drawn.
        try await waitUntil("edit mode") { viewer.contentRootForTesting.isEditModeActive }
        await viewer.waitForEditLoad()
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(viewer.displayedItem?.group.primary, b)
        XCTAssertNil(viewer.contentRootForTesting.editModeController.currentTool, "no tool is chosen")
        _ = a
    }

    /// The wait is bounded and drops the request when another photo stays on screen.
    func testEditRequestForAnotherPhotoIsDroppedAtTheTimeout() async throws {
        let a = writeJPEG("a.jpg"), b = writeJPEG("b.jpg")
        let viewer = ViewerWindow(groups: [ImageGroup(primary: a), ImageGroup(primary: b)], startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        try await waitUntil("first photo") { viewer.canPerform(.editImage) }
        viewer.enterEditModeWhenShown(b, timeout: .milliseconds(200))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive, "the shown photo is not the requested one")
    }
}

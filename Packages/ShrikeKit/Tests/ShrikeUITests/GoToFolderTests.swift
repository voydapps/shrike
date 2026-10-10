//
//  GoToFolderTests.swift
//  ShrikeUITests
//
//  Go ▸ Go to Folder… ⇧⌘G. The path rules (resolve and
//  Tab completion, both off main), the sheet (Go disabled while empty,
//  the red line for a bad path, Tab in the field), the menu item in both
//  windows, and the viewer sending its Browser there.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class GoToFolderTests: XCTestCase {

    private var dir: URL!
    private var windows: [NSWindow] = []
    private var broughtForward: [NSWindow] = []
    private var savedBringForward: (@MainActor (NSWindow) -> Void)?
    private var savedOpenBrowser: (@MainActor (GoToFolderTarget, ShrikeServices) -> BrowserWindowController)?
    private var opened: [BrowserWindowController] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-goto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        GoToFolder.lastPath = ""
        savedBringForward = ViewerWindow.bringBrowserForward
        ViewerWindow.bringBrowserForward = { [weak self] window in self?.broughtForward.append(window) }
        savedOpenBrowser = ViewerWindow.openBrowserForGoTo
        ViewerWindow.openBrowserForGoTo = { [weak self] target, services in
            let browser = BrowserWindowController(services: services, initialFolder: target.folder,
                                                  selecting: target.selecting)
            self?.opened.append(browser)
            return browser
        }
    }

    override func tearDown() async throws {
        if let savedBringForward { ViewerWindow.bringBrowserForward = savedBringForward }
        if let savedOpenBrowser { ViewerWindow.openBrowserForGoTo = savedOpenBrowser }
        opened = []
        cachedServices = nil
        for w in windows {
            if let sheet = w.attachedSheet { w.endSheet(sheet) }
            w.close()
        }
        windows = []
        GoToFolder.lastPath = ""
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func folder(_ path: String) throws -> URL {
        let url = dir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeJPEG(_ name: String, in folder: URL? = nil) -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func std(_ url: URL?) -> String? { url?.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: resolve

    func testResolveFolder() async throws {
        let pics = try folder("Pics")
        let target = await GoToFolder.resolve(pics.path)
        XCTAssertEqual(std(target?.folder), std(pics))
        XCTAssertNil(target?.selecting)
        // A trailing slash and spaces around the path are fine.
        let again = await GoToFolder.resolve("  \(pics.path)/  ")
        XCTAssertEqual(std(again?.folder), std(pics))
    }

    func testResolveFileOpensItsFolderAndSelectsIt() async throws {
        let pics = try folder("Pics")
        let file = writeJPEG("a.jpg", in: pics)
        let target = await GoToFolder.resolve(file.path)
        XCTAssertEqual(std(target?.folder), std(pics))
        XCTAssertEqual(std(target?.selecting), std(file))
    }

    func testResolveMissingIsNil() async {
        let missing = await GoToFolder.resolve(dir.appendingPathComponent("Nope/Deeper").path)
        XCTAssertNil(missing)
        let empty = await GoToFolder.resolve("   ")
        XCTAssertNil(empty)
    }

    func testResolveExpandsTilde() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let target = await GoToFolder.resolve("~")
        XCTAssertEqual(std(target?.folder), std(home))
        XCTAssertEqual(GoToFolder.expand("~/Pictures", base: nil), home.appendingPathComponent("Pictures").path)
    }

    func testResolveRelativePathStartsAtTheWindowFolder() async throws {
        let sub = try folder("Trip/Day 1")
        let target = await GoToFolder.resolve("Day 1", base: dir.appendingPathComponent("Trip"))
        XCTAssertEqual(std(target?.folder), std(sub))
    }

    // MARK: complete

    func testCompleteOneMatchFillsTheWholeNameAndASlash() async throws {
        try folder("Beta")
        try folder("Alpha")
        let completed = await GoToFolder.complete(dir.path + "/be")
        XCTAssertEqual(completed, dir.path + "/Beta/", "case does not matter")
    }

    func testCompleteSeveralMatchesFillTheCommonPrefix() async throws {
        try folder("Summer 2024")
        try folder("Summer 2025")
        writeJPEG("Summer notes.jpg")   // a file: never completed
        let completed = await GoToFolder.complete(dir.path + "/Su")
        XCTAssertEqual(completed, dir.path + "/Summer 202")
        // Already at the common prefix: nothing more to add.
        let again = await GoToFolder.complete(dir.path + "/Summer 202")
        XCTAssertNil(again)
    }

    func testCompleteNoMatchIsNil() async throws {
        try folder("Alpha")
        let completed = await GoToFolder.complete(dir.path + "/Zz")
        XCTAssertNil(completed)
        let missingParent = await GoToFolder.complete(dir.path + "/Nope/a")
        XCTAssertNil(missingParent)
    }

    func testCompleteKeepsTheTildeTheUserTyped() async {
        let completed = await GoToFolder.complete("~")
        XCTAssertEqual(completed, "~/")
    }

    func testCompleteSkipsPackages() async throws {
        try folder("Library.photoslibrary")
        try folder("Lists")
        let completed = await GoToFolder.complete(dir.path + "/Li")
        XCTAssertEqual(completed, dir.path + "/Lists/", "a package is not a folder here")
    }

    // MARK: The sheet

    private func hostWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func testSheetLayoutAndGoDisabledWhileEmpty() {
        let sheet = GoToFolderSheet(base: dir, initialPath: "")
        XCTAssertEqual(sheet.panel.contentView?.fittingSize.width, 420)
        XCTAssertEqual(sheet.fieldForTesting.placeholderString, "~/Pictures")
        XCTAssertFalse(sheet.goButtonForTesting.isEnabled, "disabled while empty")
        XCTAssertEqual(sheet.goButtonForTesting.keyEquivalent, "\r", "Go is the default button")
        XCTAssertEqual(sheet.cancelButtonForTesting.title, "Cancel")
        XCTAssertTrue(sheet.errorLabelForTesting.isHidden)
        XCTAssertEqual(sheet.errorLabelForTesting.stringValue, "There's no folder at this path.")
        XCTAssertEqual(sheet.errorLabelForTesting.textColor, .systemRed)
        XCTAssertEqual(sheet.errorLabelForTesting.font?.pointSize, 11)
        sheet.typeForTesting("   ")
        XCTAssertFalse(sheet.goButtonForTesting.isEnabled)
        sheet.typeForTesting("~/")
        XCTAssertTrue(sheet.goButtonForTesting.isEnabled)
    }

    func testBadPathShowsTheRedLineAndKeepsTheSheetOpen() async throws {
        let window = hostWindow()
        let sheet = GoToFolderSheet(base: dir, initialPath: "")
        var result: GoToFolderTarget??
        Task { result = .some(await sheet.run(on: window)) }
        try await waitUntil("sheet up") { sheet.isRunningForTesting }

        sheet.typeForTesting(dir.appendingPathComponent("Nope").path)
        sheet.goForTesting()
        await sheet.pendingTask?.value
        XCTAssertFalse(sheet.errorLabelForTesting.isHidden, "the red line shows")
        XCTAssertTrue(sheet.isRunningForTesting, "the sheet stays open")
        XCTAssertTrue(result == nil, "not finished")
        sheet.typeForTesting(dir.path)
        XCTAssertTrue(sheet.errorLabelForTesting.isHidden, "typing hides it")

        sheet.goForTesting()
        try await waitUntil("closed") { result != nil }
        XCTAssertEqual(std(result??.folder), std(dir))
        XCTAssertEqual(GoToFolder.lastPath, dir.path, "the last path is remembered")
        XCTAssertEqual(GoToFolderSheet(base: nil).fieldForTesting.stringValue, dir.path)
    }

    func testCancelReturnsNil() async throws {
        let window = hostWindow()
        let sheet = GoToFolderSheet(base: dir, initialPath: dir.path)
        var result: GoToFolderTarget??
        Task { result = .some(await sheet.run(on: window)) }
        try await waitUntil("sheet up") { sheet.isRunningForTesting }
        sheet.cancelForTesting()
        try await waitUntil("closed") { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    func testTabInTheFieldCompletes() async throws {
        try folder("Holidays")
        let sheet = GoToFolderSheet(base: dir, initialPath: "")
        sheet.typeForTesting(dir.path + "/Hol")
        let handled = sheet.control(sheet.fieldForTesting, textView: NSTextView(),
                                    doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(handled, "Tab is ours while the field has text")
        await sheet.pendingTask?.value
        XCTAssertEqual(sheet.fieldForTesting.stringValue, dir.path + "/Holidays/")
        sheet.typeForTesting("")
        XCTAssertFalse(sheet.control(sheet.fieldForTesting, textView: NSTextView(),
                                     doCommandBy: #selector(NSResponder.insertTab(_:))),
                       "an empty field lets Tab move on")
    }

    // MARK: Windows

    private var cachedServices: ShrikeServices?

    /// The shared test stores (ShrikeDataPaths test root), like the other
    /// Browser tests: a database inside `dir` is deleted under the
    /// Browser's in-flight reads.
    private func services() throws -> ShrikeServices {
        if let cachedServices { return cachedServices }
        let services = ShrikeServices.makeDefault()
        cachedServices = services
        return services
    }

    private func viewer(on photo: URL) async throws -> ViewerWindow {
        let viewer = ViewerWindow(groups: [ImageGroup(primary: photo)], startIndex: 0, services: try services())
        windows.append(viewer)
        viewer.setContentSize(NSSize(width: 600, height: 400))
        try await waitUntil("photo") { viewer.displayedItem != nil }
        return viewer
    }

    func testMenuItemIsEnabledInBothWindows() async throws {
        let photo = writeJPEG("a.jpg")
        let viewer = try await viewer(on: photo)
        XCTAssertTrue(viewer.canPerform(.goToFolder))
        let browser = BrowserWindowController(services: try services(), initialFolder: dir)
        if let w = browser.window { windows.append(w) }
        XCTAssertTrue(browser.canPerform(.goToFolder))
        XCTAssertNotNil(ShortcutTable.menuBinding(for: .goToFolder), "⇧⌘G in the Go menu")
    }

    func testBrowserGoesToTheFolderAndSelectsTheFile() async throws {
        let other = try folder("Other")
        let file = writeJPEG("b.jpg", in: other)
        writeJPEG("c.jpg", in: other)
        writeJPEG("top.jpg")
        let browser = BrowserWindowController(services: try services(), initialFolder: dir)
        if let w = browser.window { windows.append(w) }
        try await waitUntil("first listing") { browser.contentController.visibleItems.count == 1 }
        browser.go(to: .file(folder: other, file: file))
        try await waitUntil("listed") { browser.contentController.visibleItems.count == 2 }
        XCTAssertEqual(std(browser.currentFolder), std(other))
        try await waitUntil("selected") {
            browser.contentController.selectedItems.map(\.url.lastPathComponent) == ["b.jpg"]
        }
    }

    func testViewerSendsItsPairedBrowserAndBringsItForward() async throws {
        let photo = writeJPEG("a.jpg")
        let target = try folder("Target")
        let viewer = try await viewer(on: photo)
        let browser = BrowserWindowController(services: try services(), initialFolder: dir)
        if let w = browser.window { windows.append(w) }
        viewer.pair(with: browser)

        viewer.go(to: .folder(target))
        XCTAssertEqual(std(browser.currentFolder), std(target), "the paired Browser goes there")
        XCTAssertEqual(broughtForward, [browser.window].compactMap { $0 }, "and comes forward")
        XCTAssertTrue(viewer.pairedBrowser === browser)
    }

    func testViewerWithoutABrowserOpensOne() async throws {
        let photo = writeJPEG("a.jpg")
        let target = try folder("Target")
        let file = writeJPEG("t.jpg", in: target)
        let viewer = try await viewer(on: photo)
        XCTAssertNil(viewer.pairedBrowser)

        viewer.go(to: .file(folder: target, file: file))
        let browser = try XCTUnwrap(viewer.pairedBrowser, "a new Browser, paired")
        if let w = browser.window { windows.append(w) }
        XCTAssertTrue(opened.count == 1 && opened[0] === browser, "a new Browser at the folder")
        XCTAssertEqual(std(browser.currentFolder), std(target))
        XCTAssertEqual(broughtForward.count, 1)
        try await waitUntil("selected") {
            browser.contentController.selectedItems.map(\.url.lastPathComponent) == ["t.jpg"]
        }
    }

    func testViewerMenuCommandShowsTheSheetOnTheViewer() async throws {
        let photo = writeJPEG("a.jpg")
        let viewer = try await viewer(on: photo)
        viewer.perform(.goToFolder)
        let sheet = try XCTUnwrap(viewer.goToFolderSheet)
        try await waitUntil("sheet up") { sheet.isRunningForTesting }
        XCTAssertTrue(viewer.attachedSheet === sheet.panel)
        sheet.cancelForTesting()
        try await waitUntil("sheet gone") { viewer.goToFolderSheet == nil }
        XCTAssertNil(viewer.pairedBrowser, "Cancel goes nowhere")
    }
}

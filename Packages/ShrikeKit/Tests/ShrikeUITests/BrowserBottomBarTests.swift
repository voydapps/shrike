//
//  BrowserBottomBarTests.swift
//  ShrikeUITests
//
//  The Browser's bottom bar on the window's content border:
//  status strings, the path control, the thumbnail slider.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserBottomBarTests: XCTestCase {

    private var root: URL!
    private var dir: URL!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-bottombar-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func item(_ name: String, bytes: Int64, width: Int? = nil, height: Int? = nil) -> BrowserItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return BrowserItem(url: url, displayName: name, fileSize: bytes, modificationDate: Date(),
                           creationDate: nil, captureDate: nil, utType: .jpeg,
                           pixelWidth: width, pixelHeight: height, rating: 0, isFlagged: false, tags: [])
    }

    // MARK: Strings

    func testStatusStrings() {
        let mb = ByteCountFormatter.string(fromByteCount: 12_400_000, countStyle: .file)
        XCTAssertEqual(BrowserBottomBar.statusText([]), "", "none selected: empty")
        XCTAssertEqual(BrowserBottomBar.statusText([item("DSC_0042.jpg", bytes: 12_400_000, width: 6000, height: 4000)]),
                       "DSC_0042.jpg · 6000 × 4000 · \(mb)")
        XCTAssertEqual(BrowserBottomBar.statusText([item("DSC_0042.jpg", bytes: 12_400_000)]),
                       "DSC_0042.jpg · \(mb)", "dimensions only when known")
        let three = [item("a.jpg", bytes: 16_000_000), item("b.jpg", bytes: 16_000_000), item("c.jpg", bytes: 16_200_000)]
        let total = ByteCountFormatter.string(fromByteCount: 48_200_000, countStyle: .file)
        XCTAssertEqual(BrowserBottomBar.statusText(three), "3 selected · \(total)")
        XCTAssertEqual(BrowserBottomBar.sortingText(key: "Date Captured", done: 1500, total: 5000),
                       "Sorting by Date Captured… \(1500.formatted()) of \(5000.formatted())")
    }

    func testPathEntriesRunFromTheRootToTheFolder() {
        let entries = BrowserBottomBar.quickEntries(for: URL(fileURLWithPath: "/Users/me/Pictures/Shoot", isDirectory: true))
        XCTAssertEqual(entries.map(\.title), ["/", "Users", "me", "Pictures", "Shoot"])
        XCTAssertEqual(entries.last?.url.path, "/Users/me/Pictures/Shoot")
        XCTAssertTrue(entries[0].isVolume)
        let finder = BrowserBottomBar.finderEntries(for: dir)
        XCTAssertEqual(finder.last?.url.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertTrue(finder.first?.isVolume ?? false, "starts at the volume")
    }

    // MARK: In the Browser

    func testBarSitsOnTheWindowsContentBorder() async throws {
        try writeJPEG("a.jpg")
        try writeJPEG("b.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        XCTAssertEqual(window.contentBorderThickness(for: .minY), 24)
        XCTAssertFalse(window.autorecalculatesContentBorderThickness(for: .minY))
        _ = await waitUntil { browser.contentController.visibleItems.count == 2 }
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        let bar = browser.bottomBar
        XCTAssertEqual(bar.frame.height, 24)
        XCTAssertEqual(bar.frame.minY, 0)
        let statusX = bar.statusField.alignmentRect(forFrame: bar.statusField.frame).minX
        if #available(macOS 26.0, *) {
            // Clear of the large rounded corners: at
            // least 16 pt, more when the system's corner guide asks for it.
            XCTAssertGreaterThanOrEqual(statusX, 16 - 0.5, "clear of the bottom-left corner")
            XCTAssertLessThanOrEqual(bar.slider.frame.maxX, bar.bounds.maxX - 16 + 0.5)
        } else {
            XCTAssertEqual(statusX, 8, accuracy: 0.5, "8 pt inset to the text")
            XCTAssertEqual(bar.slider.frame.maxX, bar.bounds.maxX - 8, accuracy: 0.5)
        }
        XCTAssertEqual(bar.slider.frame.width, 96, accuracy: 0.5)
        XCTAssertEqual(bar.slider.controlSize, .small)
        XCTAssertEqual(bar.slider.toolTip, "Thumbnail Size")
        XCTAssertEqual(bar.pathControl.pathStyle, .standard)
        XCTAssertEqual(bar.pathControl.controlSize, .small)
        XCTAssertEqual(bar.statusField.font, NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        XCTAssertEqual(bar.statusField.textColor, .secondaryLabelColor)
        XCTAssertNil(bar.subviews.first { $0 is NSVisualEffectView }, "no custom grey strip")

        // Status follows the selection.
        // The first photo is selected when the folder opens, at once. Its
        // status text comes once the header read (JPEG listings have no
        // pixel size) ends or times out, so wait for it.
        XCTAssertEqual(browser.contentController.selectedItems.map(\.displayName), ["a.jpg"],
                       "first photo is selected when the folder opens")
        _ = await waitUntil { browser.statusTextForTesting.hasPrefix("a.jpg") }
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("a.jpg"), browser.statusTextForTesting)
        browser.contentController.selectAll()
        browser.browserContentDidSelect(browser.contentController.selectedItems)
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("2 selected · "), browser.statusTextForTesting)
        browser.sortProgressText = BrowserBottomBar.sortingText(key: "Size", done: 1, total: 2)
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("Sorting by Size…"))
        browser.sortProgressText = nil
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("2 selected"))

        // The slider shows in Grid only.
        browser.setMode(.list)
        XCTAssertTrue(bar.slider.isHidden)
        browser.setMode(.filmstrip)
        XCTAssertTrue(bar.slider.isHidden)
        browser.setMode(.grid)
        XCTAssertFalse(bar.slider.isHidden)
    }

    func testClickingAPathPartGoesThere() async throws {
        try writeJPEG("a.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 1 }
        let bar = browser.bottomBar
        let ready = await waitUntil { bar.pathURLs.last?.standardizedFileURL == self.dir.standardizedFileURL }
        XCTAssertTrue(ready)
        // A deep temp path may show a … crumb; every shown item stands for a slot.
        XCTAssertEqual(bar.pathControl.pathItems.count, bar.shownSlots.count)
        XCTAssertEqual(bar.pathControl.pathItems.last?.title, "Shoot")
        let parentIndex = bar.pathURLs.count - 2
        bar.navigate(toPathIndex: parentIndex)
        XCTAssertEqual(browser.currentFolder, root.standardizedFileURL)
        XCTAssertEqual(browser.backStack.last, dir.standardizedFileURL, "a path click is a normal navigation")
    }

    // MARK: Long paths

    func testCrumbFitKeepsFullNamesAndHidesTheMiddle() {
        typealias F = PathCrumbFit
        let w: [CGFloat] = Array(repeating: 60, count: 10)
        XCTAssertEqual(F.slots(widths: w, ellipsis: 30, available: 0), (0..<10).map(F.Slot.crumb), "no width yet: all")
        XCTAssertEqual(F.slots(widths: w, ellipsis: 30, available: 600), (0..<10).map(F.Slot.crumb), "all fit")
        XCTAssertEqual(F.slots(widths: [500, 500], ellipsis: 30, available: 100), [.crumb(0), .crumb(1)], "two: all")
        XCTAssertEqual(F.slots(widths: w, ellipsis: 30, available: 300), [.crumb(0), .hidden(1...6), .crumb(7), .crumb(8), .crumb(9)])
        XCTAssertEqual(F.slots(widths: w, ellipsis: 30, available: 100), [.hidden(0...8), .crumb(9)], "first + … + last too wide")
        XCTAssertEqual(F.slots(widths: w, ellipsis: 30, available: 50), [.crumb(9)], "only the current folder")
    }

    func testTenNestedFoldersShowTrailingNamesInFullAndAMenuForTheRest() throws {
        var deep = root!
        for i in 1...10 { deep = deep.appendingPathComponent("level\(i)", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let bar = BrowserBottomBar(slider: NSSlider())
        bar.frame = NSRect(x: 0, y: 0, width: 640, height: BrowserBottomBar.height)
        bar.setFolder(deep)
        let fullCount = bar.pathControl.pathItems.count
        let fullWidth = bar.pathControl.intrinsicContentSize.width
        bar.layoutSubtreeIfNeeded()
        let titles = bar.pathControl.pathItems.map(\.title)
        XCTAssertLessThan(titles.count, fullCount, "the chain is shortened: \(titles)")
        XCTAssertLessThan(bar.pathControl.intrinsicContentSize.width, fullWidth, "the control measures fewer items")
        XCTAssertEqual(titles.first, bar.pathControl.pathItems.first?.title)
        XCTAssertEqual(titles.filter { $0 == PathCrumbFit.ellipsis }.count, 1)
        XCTAssertEqual(titles.last, "level10")
        XCTAssertTrue(titles.suffix(3).allSatisfy { $0.hasPrefix("level") }, "trailing crumbs keep their full names: \(titles)")
        XCTAssertLessThanOrEqual(bar.pathControl.intrinsicContentSize.width, 640 - 2 * BrowserBottomBar.sideInset)
        guard case .hidden(let range)? = bar.shownSlots.first(where: { if case .hidden = $0 { return true }; return false }) else {
            return XCTFail("no … crumb")
        }
        let menu = bar.hiddenFoldersMenu(range)
        XCTAssertEqual(menu.items.map(\.title), range.map { bar.pathURLs[$0].lastPathComponent })
        var went: URL?
        bar.onNavigate = { went = $0 }
        let item = try XCTUnwrap(menu.items.last)
        bar.hiddenFolderChosen(item)
        XCTAssertEqual(went, bar.pathURLs[range.upperBound])
        // Wide again: every folder shows.
        bar.frame.size.width = 4000
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.pathControl.pathItems.count, fullCount)
    }

    /// A ten-level path in a 640 pt bar inside a window, and its `…` range.
    private func deepBarInWindow() throws -> (NSWindow, BrowserBottomBar, ClosedRange<Int>) {
        var deep = root!
        for i in 1...10 { deep = deep.appendingPathComponent("level\(i)", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = BrowserBottomBar(slider: NSSlider())
        bar.frame = NSRect(x: 0, y: 0, width: 640, height: BrowserBottomBar.height)
        window.contentView?.addSubview(bar)
        bar.setFolder(deep)
        bar.layoutSubtreeIfNeeded()
        guard case .hidden(let range)? = bar.shownSlots.first(where: { if case .hidden = $0 { return true }; return false }) else {
            XCTFail("no … crumb"); throw CancellationError()
        }
        return (window, bar, range)
    }

    /// VoiceOver: every crumb reads its full folder name (AppKit's own elements,
    /// one per item); the `…` gets a button that says how many folders it hides
    /// and whose press opens the same menu a click does.
    func testHiddenCrumbHasAVoiceOverButtonAndCrumbsReadFullNames() throws {
        let (window, bar, range) = try deepBarInWindow()
        defer { window.orderOut(nil) }
        let pathList = try XCTUnwrap((bar.pathControl.accessibilityChildren()?.first as? NSObject)?
            .accessibilityAttributeValue(.children) as? [NSObject])
        XCTAssertEqual(pathList.map { $0.accessibilityAttributeValue(.value) as? String },
                       bar.pathControl.pathItems.map(\.title), "each crumb reads its full title")
        let children = try XCTUnwrap(bar.accessibilityChildren())
        let button = try XCTUnwrap(children.compactMap { $0 as? HiddenCrumbElement }.first)
        let pathAt = try XCTUnwrap(children.firstIndex { ($0 as AnyObject) === bar.pathControl.cell })
        XCTAssertTrue(children[pathAt + 1] as AnyObject === button, "right after the path")
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "\(range.count) hidden folders")
        XCTAssertGreaterThan(button.accessibilityFrame().width, 0)
        // The checks the element itself answers (VoiceOver's own route cannot run in a test).
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertTrue(button.isAccessibilitySelectorAllowed(#selector(HiddenCrumbElement.accessibilityPerformPress)))
        // AXEnabled: a plain element says false, and VoiceOver reads it as dimmed.
        XCTAssertTrue(button.isAccessibilityEnabled(), "the button is not dimmed")
        XCTAssertTrue(button.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.isAccessibilityEnabled)))
        let above = window.contentView?.accessibilityChildren() ?? []
        XCTAssertTrue(above.contains { ($0 as AnyObject) === bar || ($0 as AnyObject) === button },
                      "the bar (and so the button) is reachable from the window: \(above)")
        var shown: NSMenu?
        bar.presentMenuForTesting = { shown = $0 }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertNil(shown, "the press returns before the (blocking) menu opens")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))   // the next main-queue turn
        XCTAssertEqual(shown?.items.map(\.title), range.map { bar.pathURLs[$0].lastPathComponent })
        XCTAssertEqual(BrowserBottomBar.hiddenFoldersLabel(1), "1 hidden folder")
        window.setContentSize(NSSize(width: 4000, height: 60))
        bar.frame.size.width = 4000
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.pathControl.pathItems.count, bar.pathURLs.count, "every folder shows")
        XCTAssertFalse(bar.accessibilityChildren()?.contains { $0 is HiddenCrumbElement } ?? true, "no … no button")
        XCTAssertFalse(button.accessibilityPerformPress())
    }

    /// The menu's items carry their folder: a path rebuilt while the menu is
    /// open cannot send the choice to another folder.
    func testHiddenFolderItemGoesToItsOwnFolderAfterThePathChanged() throws {
        let (window, bar, range) = try deepBarInWindow()
        defer { window.orderOut(nil) }
        let menu = bar.hiddenFoldersMenu(range)
        let item = try XCTUnwrap(menu.items.last)
        let expected = bar.pathURLs[range.upperBound]
        bar.setFolder(root)
        bar.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(bar.pathURLs.indices.contains(range.upperBound) ? bar.pathURLs[range.upperBound] : nil, expected)
        var went: URL?
        bar.onNavigate = { went = $0 }
        bar.hiddenFolderChosen(item)
        XCTAssertEqual(went, expected)
    }

    /// A real mouse click (down + up) on the `…` crumb opens the hidden folders' menu.
    func testClickOnHiddenCrumbOpensTheMenu() throws {
        let (window, bar, range) = try deepBarInWindow()
        defer { window.orderOut(nil) }
        let cell = try XCTUnwrap(bar.pathControl.cell as? NSPathCell)
        let index = try XCTUnwrap(bar.pathControl.pathItems.firstIndex { $0.title == PathCrumbFit.ellipsis })
        let rect = cell.rect(of: cell.pathComponentCells[index], withFrame: bar.pathControl.bounds, in: bar.pathControl)
        let point = bar.pathControl.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point) === bar.pathControl, "the click reaches the path control")
        var shown: NSMenu?
        bar.presentMenuForTesting = { shown = $0 }
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func click(_ point: NSPoint) throws {
            let down = try XCTUnwrap(event(.leftMouseDown, at: point)), up = try XCTUnwrap(event(.leftMouseUp, at: point))
            NSApp?.postEvent(up, atStart: true)
            bar.pathControl.mouseDown(with: down)
            // A mouse-up the control's own tracking did not take would wait in the queue.
            _ = NSApp?.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        }
        try click(point)
        XCTAssertEqual(shown?.items.map(\.title), range.map { bar.pathURLs[$0].lastPathComponent }, "the click opens the menu")
        // A plain crumb still goes to its folder through the control's own click.
        var went: URL?
        bar.onNavigate = { went = $0 }
        let next = cell.rect(of: cell.pathComponentCells[index + 1], withFrame: bar.pathControl.bounds, in: bar.pathControl)
        try click(bar.pathControl.convert(NSPoint(x: next.midX, y: next.midY), to: nil))
        XCTAssertEqual(went, bar.pathURLs[range.upperBound + 1], "a folder crumb navigates")
    }
}

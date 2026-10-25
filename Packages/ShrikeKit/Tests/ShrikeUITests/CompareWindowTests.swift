//
//  CompareWindowTests.swift
//  ShrikeUITests
//
//  The Compare window. The tests run on offscreen windows
//  (never ordered in); a fake Trash (a temp folder) stands in for the
//  user's Trash through `FileOps`'s `trashItem:` seam.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class CompareWindowTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var fakeTrash: URL!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-compare-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        CompareWindow.presentsWindows = false
    }

    override func tearDown() async throws {
        CompareWindow.current?.close()
        CompareWindow.presentsWindows = true
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 1200, height: Int = 900) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func fakeOps() -> FileOps {
        let trash = fakeTrash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func browser(_ names: [String]) async throws -> BrowserWindowController {
        for name in names { try writeJPEG(name) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == names.count }
        XCTAssertTrue(listed)
        return browser
    }

    private func names(_ window: CompareWindow) -> [String] {
        window.panes.map { window.list[$0.index].primary.lastPathComponent }
    }

    private func selectedNames(_ browser: BrowserWindowController) -> [String] {
        browser.contentController.selectedItems.map(\.url.lastPathComponent)
    }

    private func key(_ key: String, _ flags: NSEvent.ModifierFlags = []) -> CompareKeyMap.Hit? {
        CompareKeyMap.hit(for: KeyEventSnapshot(key: key, modifiers: flags), preset: .macNative)
    }

    // MARK: Pure parts

    func testSourcesFollowTheTable() {
        let list = (0..<6).map { ImageGroup(primary: URL(fileURLWithPath: "/tmp/\($0).jpg")) }
        XCTAssertNil(CompareSources.fromBrowser(list: list, selected: []))
        XCTAssertEqual(CompareSources.fromBrowser(list: list, selected: [2])?.shown, [2, 3], "1 = it and the next")
        XCTAssertEqual(CompareSources.fromBrowser(list: list, selected: [5])?.shown, [4, 5], "the last one pairs with the one before")
        XCTAssertEqual(CompareSources.fromBrowser(list: list, selected: [4, 1, 3])?.shown, [1, 3, 4])
        let five = CompareSources.fromBrowser(list: list, selected: [0, 1, 2, 3, 5])
        XCTAssertEqual(five?.shown, [0, 1, 2, 3])
        XCTAssertEqual(five?.truncated, true)
        XCTAssertEqual(CompareSources.truncatedToast, "Compare shows up to 4 photos. Showing the first 4.")
        XCTAssertEqual(CompareSources.fromViewer(list: list, displayed: 3)?.shown, [3, 4])
        XCTAssertNil(CompareSources.fromViewer(list: Array(list.prefix(1)), displayed: 0))
    }

    func testLayoutIsSideBySideThreeColumnsOrTwoByTwo() {
        let bounds = CGRect(x: 0, y: 0, width: 1201, height: 801)
        let two = CompareLayout.frames(count: 2, in: bounds)
        XCTAssertEqual(two.map(\.minY), [0, 0])
        XCTAssertEqual(two[0].maxX + 1, two[1].minX, "1 pt gutter")
        XCTAssertEqual(two[1].maxX, 1201)
        let three = CompareLayout.frames(count: 3, in: bounds)
        XCTAssertEqual(Set(three.map(\.minY)), [0])
        XCTAssertEqual(three[0].maxX + 1, three[1].minX)
        XCTAssertEqual(three[1].maxX + 1, three[2].minX)
        let four = CompareLayout.frames(count: 4, in: bounds)
        XCTAssertEqual(four[0].minY, four[1].minY)
        XCTAssertGreaterThan(four[0].minY, four[2].minY, "panes 1–2 are the top row")
        XCTAssertEqual(four[2].maxY + 1, four[0].minY)
        XCTAssertEqual(four[2].minY, 0)
        XCTAssertEqual(four[0].maxY, 801)
    }

    func testFooterTextAndErrorText() {
        XCTAssertEqual(CompareFooter.text(name: "DSC_0042.jpg", rating: 3, flagged: true,
                                          pixelSize: CGSize(width: 6000, height: 4000),
                                          aperture: 2.8, shutter: 1.0 / 250, iso: 200),
                       "DSC_0042.jpg  ★★★ ⚑   6000 × 4000   ƒ/2.8  1/250 s  ISO 200")
        XCTAssertEqual(CompareFooter.text(name: "a.png", rating: 0, flagged: false, pixelSize: nil,
                                          aperture: nil, shutter: nil, iso: nil), "a.png")
        XCTAssertEqual(CompareFooter.errorText("x.jpg"), "Shrike can't open “x.jpg”.")
    }

    // Spec 25 §11.
    func testTabKeysAndRingAndSubtitle() async throws {
        XCTAssertEqual(key(SpecialKey.tab)?.command, .compareFocusNext)
        XCTAssertEqual(key(SpecialKey.tab, .shift)?.command, .compareFocusPrevious)
        XCTAssertEqual(CompareFocusRingView.width, 3)
        XCTAssertEqual(CompareWindow.subtitle(paneCount: 2), "2 photos · Tab switches pane · arrows change candidates")
        XCTAssertEqual(CompareWindow.subtitle(paneCount: 1), "1 photo")

        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg"])
        defer { browser.close() }
        browser.contentController.select(urls: ["a.jpg", "b.jpg", "c.jpg"].map { dir.appendingPathComponent($0) })
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        XCTAssertEqual(window.focusedIndex, 0)
        window.perform(try XCTUnwrap(key(SpecialKey.tab)))
        XCTAssertEqual(window.focusedIndex, 1)
        window.perform(try XCTUnwrap(key(SpecialKey.tab)))
        window.perform(try XCTUnwrap(key(SpecialKey.tab)))
        XCTAssertEqual(window.focusedIndex, 0, "wraps")
        window.perform(try XCTUnwrap(key(SpecialKey.tab, .shift)))
        XCTAssertEqual(window.focusedIndex, 2, "⇧Tab from the first goes to the last")
        XCTAssertEqual(window.panes.map(\.view.footerAlphaForTesting), [0.6, 0.6, 1])
        XCTAssertFalse(window.firstResponder is NSButton, "Tab does not move the key view to a button")
    }

    /// The unfocused footers are dimmed on screen, not just in a property: the brightest
    /// footer pixel of an unfocused pane is clearly darker than the focused pane's.
    func testUnfocusedFooterIsDrawnDimmer() async throws {
        let browser = try await browser(["a.jpg", "b.jpg"])
        defer { browser.close() }
        browser.contentController.select(urls: ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) })
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        window.setContentSize(NSSize(width: 900, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        func peak(_ pane: ComparePaneView) -> Double {
            pane.layoutSubtreeIfNeeded()
            let rect = pane.footer.convert(pane.footer.bounds, to: pane)
            let size = pane.bounds.size
            guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return 0 }
            pane.cacheDisplay(in: pane.bounds, to: rep)
            var best = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let px = CGPoint(x: Double(x) / Double(rep.pixelsWide) * size.width,
                                     y: Double(y) / Double(rep.pixelsHigh) * size.height)
                    // bitmap rows run top-down; the pane is not flipped
                    let flipped = CGPoint(x: px.x, y: size.height - px.y)
                    guard rect.contains(flipped),
                          let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    best = max(best, Double(c.redComponent + c.greenComponent + c.blueComponent) / 3)
                }
            }
            return best
        }
        XCTAssertEqual(window.focusedIndex, 0)
        let focused = peak(window.panes[0].view)
        let dimmed = peak(window.panes[1].view)
        XCTAssertGreaterThan(focused, 0.5, "the focused footer text is drawn")
        XCTAssertLessThan(dimmed, focused - 0.15, "the unfocused footer is dimmer (\(dimmed) vs \(focused))")
    }

    func testKeysFollowSection9() {
        XCTAssertEqual(key(SpecialKey.right)?.command, .nextImage)
        XCTAssertEqual(key(SpecialKey.right, .shift)?.command, .compareNextAll)
        XCTAssertEqual(key("0")?.command, .compareFitAll)
        XCTAssertEqual(key("s")?.command, .compareLock)
        XCTAssertEqual(key("3")?.command, .rate3)
        XCTAssertEqual(key("3")?.allPanes, false)
        let all = CompareKeyMap.hit(for: KeyEventSnapshot(key: "#", modifiers: .shift), unshiftedKey: "3",
                                    preset: .macNative)
        XCTAssertEqual(all, CompareKeyMap.Hit(command: .rate3, allPanes: true), "⇧ = all panes")
        XCTAssertEqual(key("q", .shift), CompareKeyMap.Hit(command: .toggleFlag, allPanes: true))
        XCTAssertEqual(key("2", .command)?.command, .compareFocus2)
        XCTAssertEqual(key("l", .command)?.command, .rotateLeft)
        XCTAssertNil(key(SpecialKey.backspace), "plain ⌫ trashes nothing in the Mac preset")
        XCTAssertEqual(key(SpecialKey.backspace, .command)?.command, .moveToTrash)
        XCTAssertEqual(key(SpecialKey.escape)?.command, .escape)
        // FastStone: ⌃1–⌃5 rate, L / R rotate, ⌦ trashes.
        let fs = { (k: String, f: NSEvent.ModifierFlags) in
            CompareKeyMap.hit(for: KeyEventSnapshot(key: k, modifiers: f), preset: .fastStoneCompat)?.command
        }
        XCTAssertEqual(fs("4", .control), .rate4)
        XCTAssertEqual(fs("r", []), .rotateRight)
        XCTAssertEqual(fs(SpecialKey.forwardDelete, []), .moveToTrash)
        XCTAssertNil(fs(SpecialKey.backspace, []), "bare ⌫ never trashes in FastStone")
        XCTAssertEqual(ShortcutTable.tooltip(for: .compareLock, context: .compare), "Sync Zoom and Pan  ·  S")
        XCTAssertEqual(ShortcutTable.tooltip(for: .compareFitAll, context: .compare), "Fit All  ·  0")
    }

    // MARK: Select 3, ⌘4 → 3 columns

    func testVector1ThreeSelectedOpenInThreeColumns() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        browser.contentController.select(urls: ["a.jpg", "c.jpg", "d.jpg"].map { dir.appendingPathComponent($0) })
        XCTAssertTrue(browser.canPerform(.compare))
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        XCTAssertEqual(names(window), ["a.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(window.subtitle, "3 photos · Tab switches pane · arrows change candidates")
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutPanes()
        let frames = window.panes.map(\.view.frame)
        XCTAssertEqual(Set(frames.map(\.minY)).count, 1, "one row")
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        XCTAssertEqual(frames[0].width, 1200.0 / 3, accuracy: 1.5)
        XCTAssertTrue(window.panes[0].view.isFocused)
        XCTAssertFalse(window.panes[1].view.isFocused)
        // Toolbar: only Lock and Fit All, with the resolver's tooltips.
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.lockToolbarItem?.toolTip, "Zoom and pan in all panes together. Sync Zoom and Pan  ·  S")
        XCTAssertEqual(window.fitAllToolbarItem?.toolTip, "Fit All  ·  0")
        // The panes load (a footer with the name).
        let loaded = await waitUntil { window.panes.allSatisfy { $0.view.imageView.image != nil } }
        XCTAssertTrue(loaded)
        XCTAssertTrue(window.panes[1].view.footerLabel.stringValue.hasPrefix("c.jpg"))
        // ⌘2 focuses pane 2; a second ⌘4 with 1 selected reuses the window.
        window.perform(try XCTUnwrap(key("2", .command)))
        XCTAssertTrue(window.panes[1].view.isFocused)
        browser.contentController.select(urls: [dir.appendingPathComponent("e.jpg")])
        browser.perform(.compare)
        XCTAssertTrue(CompareWindow.current === window, "one Compare window, reused")
        XCTAssertEqual(names(window), ["d.jpg", "e.jpg"])
        // Closing frees every texture at once.
        let views = window.panes.map(\.view.imageView)
        window.close()
        XCTAssertNil(CompareWindow.current)
        XCTAssertTrue(views.allSatisfy { $0.image == nil })
    }

    /// Compare from the Browser cascades 24 pt, like the
    /// paired viewer, instead of covering the Browser exactly.
    func testCompareFromTheBrowserCascadesLikeTheViewer() async throws {
        let browser = try await browser(["a.jpg", "b.jpg"])
        defer { browser.close() }
        let browserWindow = try XCTUnwrap(browser.window)
        // The Browser starts fully inside the visible screen (hosted runners
        // have a 1024 x 768 display with a 674 pt tall visible area).
        let screenVisible = try XCTUnwrap(browserWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        browserWindow.setFrame(NSRect(x: screenVisible.minX + 100, y: screenVisible.minY + 100,
                                      width: min(1000, screenVisible.width - 100),
                                      height: min(600, screenVisible.height - 100)), display: false)
        let browserFrame = browserWindow.frame
        let visible = try XCTUnwrap(browserWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        XCTAssertTrue(visible.contains(browserFrame), "fixture: the Browser fits the visible screen \(visible)")
        browser.contentController.selectAll()
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        let frame = window.frame
        let desiredX = browserFrame.minX + 24
        let desiredMinY = browserFrame.minY - 24
        let desiredMaxY = browserFrame.maxY - 24

        // Check the cascade against the Browser and visible screen geometry,
        // independently of the production frame helper used to create it.
        if desiredX + browserFrame.width <= visible.maxX {
            XCTAssertEqual(frame.minX, desiredX, accuracy: 0.5, "keep the 24 pt right cascade when it fits")
            XCTAssertEqual(frame.width, browserFrame.width, accuracy: 0.5,
                           "keep the Browser width when the screen has room")
        } else {
            let expectedWidth = min(browserFrame.width, visible.maxX - desiredX)
            XCTAssertEqual(frame.minX, desiredX, accuracy: 0.5, "horizontal clamping keeps the cascade origin")
            XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.5,
                           "shrink the paired window only enough to fit the visible screen")
            XCTAssertLessThan(frame.width, browserFrame.width)
            XCTAssertGreaterThanOrEqual(frame.width, min(CompareWindow.minimumWindowSize.width, visible.width),
                                        "retain Compare's minimum usable width when the display allows it")
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + 0.5)
        }

        if desiredMinY >= visible.minY {
            XCTAssertEqual(frame.minY, desiredMinY, accuracy: 0.5, "keep the 24 pt downward cascade when it fits")
            XCTAssertEqual(frame.height, browserFrame.height, accuracy: 0.5,
                           "keep the Browser height when the screen has room")
        } else {
            let expectedMinY = max(visible.minY, browserFrame.minY)
            XCTAssertEqual(frame.maxY, desiredMaxY, accuracy: 0.5,
                           "vertical clamping preserves the cascaded top edge")
            XCTAssertEqual(frame.minY, expectedMinY, accuracy: 0.5,
                           "vertical clamping raises the lower edge to the screen or Browser origin")
            XCTAssertEqual(frame.height, desiredMaxY - expectedMinY, accuracy: 0.5,
                           "vertical clamp computes the visible paired-window height")
            XCTAssertLessThan(frame.height, browserFrame.height)
        }
        XCTAssertTrue(visible.contains(frame), "Compare frame remains within the visible screen: \(frame)")
        XCTAssertNotEqual(frame, browserFrame, "Compare must remain visibly cascaded or screen-clamped")
    }

    func testCompareCascadeFits1024PointAndMinimumDisplays() {
        let visible = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let browser = NSRect(x: 100, y: 100, width: 1024, height: 600)
        let frame = WindowCoordinator.pairedViewerFrame(over: browser, visible: visible)
        XCTAssertEqual(frame.minX, 124, accuracy: 0.5, "keep the 24 pt cascade when it fits")
        XCTAssertEqual(frame.width, 900, accuracy: 0.5,
                       "use the 900 pt remaining to the right edge instead of growing past 1024")
        XCTAssertTrue(visible.contains(frame), "the 1024 pt display contains the full Compare window")
        XCTAssertGreaterThanOrEqual(frame.width, CompareWindow.minimumWindowSize.width)

        let minimumDisplay = NSRect(x: 0, y: 0, width: 400, height: 250)
        let minimumFrame = WindowCoordinator.pairedViewerFrame(
            over: NSRect(x: 50, y: 30, width: 800, height: 500), visible: minimumDisplay)
        XCTAssertTrue(minimumDisplay.contains(minimumFrame),
                      "when the display is below Compare's normal minimum, the window fits the available display")
        XCTAssertEqual(minimumFrame.size, minimumDisplay.size)
        XCTAssertEqual(min(CompareWindow.minimumWindowSize.width, minimumDisplay.width), minimumFrame.width)
    }

    func testOverFourSelectedShowsTheFirstFourWithAToast() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        browser.contentController.selectAll()
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        XCTAssertEqual(names(window), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(window.toastsForTesting, ["Compare shows up to 4 photos. Showing the first 4."])
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.layoutPanes()
        let frames = window.panes.map(\.view.frame)
        XCTAssertEqual(frames[0].minY, frames[1].minY)
        XCTAssertGreaterThan(frames[0].minY, frames[2].minY, "2 × 2")
    }

    // MARK: Locked, 200 % in pane 1 → every pane 200 % at the same relative point

    func testVector2LockSharesZoomAndRelativePosition() async throws {
        try writeJPEG("a.jpg", width: 1200, height: 900)
        try writeJPEG("b.jpg", width: 1600, height: 1200)
        try writeJPEG("c.jpg", width: 900, height: 1200)
        let groups = ["a.jpg", "b.jpg", "c.jpg"].map { ImageGroup(primary: dir.appendingPathComponent($0)) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let window = CompareWindow.open(CompareRequest(list: groups, shown: [0, 1, 2], truncated: false),
                                        services: services, origin: nil, frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        defer { window.close() }
        let loaded = await waitUntil {
            window.panes.allSatisfy { $0.view.imageView.image != nil && $0.view.imageView.sourcePixelSize != nil }
        }
        XCTAssertTrue(loaded)
        XCTAssertTrue(window.isLocked, "Lock is on by default")
        let lead = window.panes[0].view.imageView
        // 200 %, anchored off-centre so the relative point is not ½, ½.
        lead.setPixelScale(2.0, anchor: CGPoint(x: lead.bounds.width * 0.25, y: lead.bounds.height * 0.7))
        let relative = CompareLock.relativeCentre(imageRect: lead.drawnImageRect, viewBounds: lead.bounds)
        XCTAssertNotEqual(relative.x, 0.5, accuracy: 0.01)
        for pane in window.panes {
            let view = pane.view.imageView
            XCTAssertEqual(view.pixelScale, 2.0, accuracy: 0.01)
            let r = CompareLock.relativeCentre(imageRect: view.drawnImageRect, viewBounds: view.bounds)
            XCTAssertEqual(r.x, relative.x, accuracy: 0.01)
            XCTAssertEqual(r.y, relative.y, accuracy: 0.01)
        }
        // A pan in pane 2 moves the others to the same relative point.
        let second = window.panes[1].view.imageView
        second.pan = CGPoint(x: second.pan.x - 40, y: second.pan.y + 30)
        let moved = CompareLock.relativeCentre(imageRect: second.drawnImageRect, viewBounds: second.bounds)
        let first = CompareLock.relativeCentre(imageRect: lead.drawnImageRect, viewBounds: lead.bounds)
        XCTAssertEqual(first.x, moved.x, accuracy: 0.01)
        XCTAssertEqual(first.y, moved.y, accuracy: 0.01)
        // `0` fits every pane; unlocked, a zoom stays in its pane.
        window.perform(try XCTUnwrap(key("0")))
        XCTAssertTrue(window.panes.allSatisfy { $0.view.imageView.isAtFit })
        window.perform(try XCTUnwrap(key("s")))
        XCTAssertFalse(window.isLocked)
        lead.setPixelScale(2.0, anchor: nil)
        XCTAssertTrue(window.panes[1].view.imageView.isAtFit, "unlocked panes zoom on their own")
    }

    func testSyncToolbarAccessibleLabelTracksActualActionAndShortcut() async throws {
        let urls = try [writeJPEG("sync-a.jpg"), writeJPEG("sync-b.jpg")]
        let window = CompareWindow.open(CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: ShrikeServices.makeDefault(), origin: nil, frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        defer { window.close() }
        let loaded = await waitUntil { window.panes.allSatisfy { $0.view.imageView.image != nil && $0.view.imageView.sourcePixelSize != nil } }
        XCTAssertTrue(loaded)
        let item = try XCTUnwrap(window.lockToolbarItem), action = try XCTUnwrap(item.action)
        XCTAssertTrue(item.target === window)
        XCTAssertEqual(action, #selector(CompareWindow.toggleLockFromToolbar(_:)))
        func currentAccessibleLabels() -> [String] {
            window.contentView?.superview?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            var labels: [String] = [], visited: Set<ObjectIdentifier> = []
            func walk(_ value: Any, depth: Int) {
                let element = value as AnyObject
                guard depth < 20, visited.insert(ObjectIdentifier(element)).inserted else { return }
                if let label = element.accessibilityLabel?(), label.hasPrefix("Sync Zoom and Pan:") {
                    labels.append(label)
                }
                for child in (element.accessibilityChildren?() ?? nil) ?? [] { walk(child, depth: depth + 1) }
            }
            if let frame = window.contentView?.superview { walk(frame, depth: 0) }
            return labels
        }
        XCTAssertTrue(window.isLocked)
        XCTAssertEqual(item.label, "Sync Zoom and Pan: On")
        let initial = await waitUntil { currentAccessibleLabels().contains("Sync Zoom and Pan: On") }
        XCTAssertTrue(initial, "the actual toolbar accessibility control exposes its initial state")
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertFalse(window.isLocked)
        XCTAssertEqual(item.label, "Sync Zoom and Pan: Off")
        let off = await waitUntil { currentAccessibleLabels().contains("Sync Zoom and Pan: Off") }
        XCTAssertTrue(off, "the toolbar action updates its readable current state")
        let lead = window.panes[0].view.imageView
        lead.setPixelScale(2, anchor: nil)
        XCTAssertTrue(window.panes[1].view.imageView.isAtFit, "turning sync off preserves independent zoom")
        window.perform(try XCTUnwrap(key("s")))
        XCTAssertTrue(window.isLocked)
        XCTAssertEqual(item.label, "Sync Zoom and Pan: On")
        let on = await waitUntil { currentAccessibleLabels().contains("Sync Zoom and Pan: On") }
        XCTAssertTrue(on, "the shortcut uses the same stateful toolbar control")
        XCTAssertEqual(window.panes[1].view.imageView.pixelScale, 2, accuracy: 0.01)
        XCTAssertTrue(item.target === window); XCTAssertEqual(item.action, action)
    }

    // MARK: ⌫ on pane 2 → the next image not shown; ⌘Z brings it back

    func testVector3TrashShowsTheNextUnusedImageAndUndoBringsItBack() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        browser.contentController.select(urls: ["a.jpg", "b.jpg", "c.jpg"].map { dir.appendingPathComponent($0) })
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        window.fileOps = fakeOps()
        window.focus(1)
        window.perform(try XCTUnwrap(key(SpecialKey.backspace, .command)))
        // Same turn: pane 2 moves past c.jpg (pane 3 shows it) to d.jpg.
        XCTAssertEqual(names(window), ["a.jpg", "d.jpg", "c.jpg"])
        await window.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.jpg").path))
        XCTAssertEqual(window.compareUndoManager.undoActionName, "Move to Trash")
        XCTAssertEqual(browser.contentController.visibleItems.count, 4, "the Browser drops it too")

        window.compareUndoManager.undo()
        await window.waitForPendingTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.jpg").path))
        XCTAssertEqual(names(window), ["a.jpg", "b.jpg", "c.jpg"], "back in the pane it left")
        XCTAssertEqual(window.list.count, 5)
    }

    func testTrashWithNoImageLeftClosesThePaneAndUndoReopensIt() async throws {
        let urls = try ["a.jpg", "b.jpg"].map { try writeJPEG($0) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let window = CompareWindow.open(CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1],
                                                       truncated: false),
                                        services: services, origin: nil, frame: nil)
        defer { window.close() }
        window.fileOps = fakeOps()
        window.trashFocused()
        XCTAssertEqual(names(window), ["b.jpg"], "the layout shrinks to one pane")
        await window.waitForPendingTrash()
        window.compareUndoManager.undo()
        await window.waitForPendingTrash()
        XCTAssertEqual(names(window), ["a.jpg", "b.jpg"], "a new pane at its old place")
        XCTAssertTrue(window.panes[0].view.isFocused)
    }

    // MARK: Esc → the Browser's selection is unchanged, less trashed items

    func testVector4EscKeepsTheBrowserSelectionLessTrashedItems() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        defer { browser.close() }
        browser.contentController.select(urls: ["a.jpg", "b.jpg", "c.jpg"].map { dir.appendingPathComponent($0) })
        browser.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        window.fileOps = fakeOps()
        window.focus(1)
        window.trashFocused()
        await window.waitForPendingTrash()
        window.perform(try XCTUnwrap(key(SpecialKey.escape)))
        XCTAssertTrue(window.isClosedForTesting)
        XCTAssertNil(CompareWindow.current)
        XCTAssertEqual(selectedNames(browser), ["a.jpg", "c.jpg"])
    }

    // MARK: Culling through CullingUndo

    func testRatingGoesToTheFocusedPaneAndShiftToAll() async throws {
        let urls = try ["a.jpg", "b.jpg", "c.jpg"].map { try writeJPEG($0) }
        let services = ShrikeServices.makeDefault()
        let window = CompareWindow.open(CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1],
                                                       truncated: false),
                                        services: services, origin: nil, frame: nil)
        defer { window.close() }
        window.focus(1)
        window.perform(try XCTUnwrap(key("4")))
        await window.waitForCullingWrites()
        var records = await services.metadataStore.records(for: urls)
        XCTAssertEqual(records[urls[1]]?.rating, 4)
        XCTAssertEqual(records[urls[0]]?.rating ?? 0, 0)
        XCTAssertTrue(window.panes[1].view.footerLabel.stringValue.contains("★★★★"))
        window.perform(CompareKeyMap.Hit(command: .toggleFlag, allPanes: true))
        await window.waitForCullingWrites()
        records = await services.metadataStore.records(for: urls)
        XCTAssertEqual(records[urls[0]]?.flagged, true)
        XCTAssertEqual(records[urls[1]]?.flagged, true)
        XCTAssertEqual(window.compareUndoManager.undoActionName, Culling.actionName(.flag))
        window.compareUndoManager.undo()
        await window.waitForCullingWrites()
        records = await services.metadataStore.records(for: urls)
        XCTAssertEqual(records[urls[0]]?.flagged ?? false, false)
        XCTAssertEqual(records[urls[1]]?.rating, 4)
    }

    func testViewerOpensTheShownPhotoAndTheNext() throws {
        let urls = try ["a.jpg", "b.jpg", "c.jpg"].map { try writeJPEG($0) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 1, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(1)
        XCTAssertTrue(viewer.canPerform(.compare))
        viewer.perform(.compare)
        let window = try XCTUnwrap(CompareWindow.current)
        XCTAssertEqual(names(window), ["b.jpg", "c.jpg"])
        XCTAssertEqual(window.frame, viewer.frame, "from a viewer: opens at the viewer's frame")
    }

    // MARK: Esc hands the keys back

    private static func event(_ chars: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    private static let esc = event("\u{1b}", keyCode: 53)

    /// After Esc closes Compare, the Browser's grid (or list) is the
    /// first responder again, so the next ⇧-arrow extends the selection.
    func testEscHandsTheKeysBackToTheBrowserGridOrList() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        let browserWindow = try XCTUnwrap(browser.window)
        browserWindow.setContentSize(NSSize(width: 1280, height: 800))
        browserWindow.contentView?.layoutSubtreeIfNeeded()
        for mode in [BrowserViewMode.grid, .list] {
            browser.setMode(mode)
            let focus = browser.contentController.focusView
            browser.contentController.select(urls: ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) })
            // The keys were somewhere else when Compare opened.
            browserWindow.makeFirstResponder(nil)
            XCTAssertFalse(browserWindow.firstResponder === focus)
            browser.perform(.compare)
            let compare = try XCTUnwrap(CompareWindow.current)
            compare.keyDown(with: Self.esc)
            XCTAssertTrue(compare.isClosedForTesting, "\(mode)")
            XCTAssertTrue(browserWindow.firstResponder === focus, "\(mode): the grid / list has the keys")
            XCTAssertEqual(selectedNames(browser), ["a.jpg", "b.jpg"])
        }
        // ⇧↓ right away extends the list selection by one.
        browserWindow.firstResponder?.keyDown(with: Self.event(SpecialKey.down, .shift, keyCode: 125))
        XCTAssertEqual(selectedNames(browser), ["a.jpg", "b.jpg", "c.jpg"])
    }

    // MARK: The mouse wheel in a pane follows the viewer

    /// A notched-wheel event (lines, not continuous) over `view`'s centre.
    private func wheel(_ window: CompareWindow, over view: NSView, lines: Int32,
                       flags: CGEventFlags = []) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                       wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg.flags = flags
        let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: p)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                value: Int64(window.windowNumber))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// Delivered like `NSWindow` does: to the view hit at the point
    /// (an offscreen window is unknown to the window server).
    private func send(_ window: CompareWindow, _ event: NSEvent, over view: NSView) throws {
        XCTAssertFalse(event.hasPreciseScrollingDeltas, "a notched wheel")
        if event.window === window { window.sendEvent(event); return }
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let inFrameSuper = frameView.superview.map { $0.convert(p, from: nil) } ?? frameView.convert(p, from: nil)
        let hit = try XCTUnwrap(frameView.hitTest(inFrameSuper))
        XCTAssertTrue(hit === view || hit.isDescendant(of: view), "the pane's canvas is under the pointer")
        hit.scrollWheel(with: event)
    }

    /// Default pref ("Changes image"): at Fit the wheel changes the photo
    /// of the pane under the pointer, as in the viewer; ⌘ + wheel zooms
    /// at the pointer (Lock on: every pane follows); zoomed in, the wheel
    /// pans and never changes the photo.
    func testMouseWheelInAPaneFollowsTheViewerRules() async throws {
        let saved = Prefs.scrollWheelNavigates
        Prefs.scrollWheelNavigates = true
        defer { Prefs.scrollWheelNavigates = saved }
        let urls = try ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map { try writeJPEG($0) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let window = CompareWindow.open(CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1],
                                                       truncated: false),
                                        services: services, origin: nil,
                                        frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        defer { window.close() }
        let loaded = await waitUntil { window.panes.allSatisfy { $0.view.imageView.image != nil } }
        XCTAssertTrue(loaded)
        window.focus(1)
        let first = window.panes[0].view.imageView

        // At Fit: one notch down = the next photo in that pane (and focus).
        try send(window, try wheel(window, over: first, lines: -1), over: first)
        XCTAssertEqual(window.panes[0].index, 1)
        XCTAssertTrue(window.panes[0].view.isFocused)
        let reloaded = await waitUntil { first.image != nil && first.isAtFit }
        XCTAssertTrue(reloaded)
        try await Task.sleep(for: .milliseconds(80))   // past the 60 ms wheel pause

        // ⌘ + wheel up: zoom in at the pointer; locked, pane 2 follows.
        // 0.2.10: a notch zooms 12 %, so three notches leave room to pan.
        for _ in 0..<3 {
            try send(window, try wheel(window, over: first, lines: 1, flags: .maskCommand), over: first)
        }
        XCTAssertFalse(first.isAtFit)
        XCTAssertEqual(window.panes[0].index, 1, "⌘ + wheel never changes the photo")
        XCTAssertEqual(window.panes[1].view.imageView.pixelScale, first.pixelScale, accuracy: 0.01)

        // Zoomed in: a plain notch pans; the photo stays.
        let pan = first.pan
        try send(window, try wheel(window, over: first, lines: -1), over: first)
        XCTAssertEqual(window.panes[0].index, 1)
        XCTAssertNotEqual(first.pan, pan, "zoomed in, the wheel pans")
    }

    /// From a viewer: its canvas takes the keys back.
    func testEscHandsTheKeysBackToTheViewerCanvas() throws {
        let urls = try ["a.jpg", "b.jpg", "c.jpg"].map { try writeJPEG($0) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        viewer.makeFirstResponder(nil)
        viewer.perform(.compare)
        let compare = try XCTUnwrap(CompareWindow.current)
        compare.keyDown(with: Self.esc)
        XCTAssertTrue(compare.isClosedForTesting)
        XCTAssertTrue(viewer.firstResponder === viewer.canvasResponder)
    }

    /// Audit on-screen M3: with the panes zoomed, → on a pane brings the next photo at the
    /// SAME zoom (the file size is known only after the info read; the zoom is applied then).
    func testNextCandidateKeepsTheSharedZoom() async throws {
        // The third photo has other pixel dimensions than the pane's old one: the old
        // pane keeps its previous size until the new file's size is read.
        let groups = [ImageGroup(primary: try writeJPEG("a.jpg", width: 6000, height: 4000)),
                      ImageGroup(primary: try writeJPEG("b.jpg", width: 6000, height: 4000)),
                      ImageGroup(primary: try writeJPEG("c.jpg", width: 2400, height: 1600))]
        let services = ShrikeServices.makeDefault()
        let window = CompareWindow.open(CompareRequest(list: groups, shown: [0, 1], truncated: false),
                                        services: services, origin: nil, frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        defer { window.close() }
        let loaded = await waitUntil {
            window.panes.allSatisfy { $0.view.imageView.image != nil && $0.view.imageView.sourcePixelSize != nil }
        }
        XCTAssertTrue(loaded)
        XCTAssertTrue(window.isLocked)
        window.focus(0)
        let lead = window.panes[0].view.imageView
        lead.setPixelScale(2.0, anchor: nil)
        XCTAssertEqual(window.panes[1].view.imageView.pixelScale, 2.0, accuracy: 0.01)

        window.panes[1].view.onNext?()
        XCTAssertEqual(window.panes[1].index, 2)
        let settled = await waitUntil {
            let v = window.panes[1].view.imageView
            return window.panes[1].loadedURL == groups[2].primary && v.sourcePixelSize != nil
                && abs(v.pixelScale - 2.0) < 0.01
        }
        XCTAssertTrue(settled, "pane 2 shows the new photo at \(window.panes[1].view.imageView.pixelScale) (want 2.0)")
        XCTAssertEqual(lead.pixelScale, 2.0, accuracy: 0.01, "the other pane did not move")
    }
}

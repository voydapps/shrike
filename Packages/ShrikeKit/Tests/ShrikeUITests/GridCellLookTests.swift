//
//  GridCellLookTests.swift
//  ShrikeUITests
//
//  Grid cell look (ring outside the card, capsule behind the
//  name, key / not key), decode failure, and live colours.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class GridCellLookTests: XCTestCase {

    private var dir: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-cells-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ShrikeTokens.increaseContrastOverride = false
    }

    override func tearDown() async throws {
        ShrikeTokens.increaseContrastOverride = nil
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    /// A cell `width` pt wide in an offscreen window.
    private func makeCell(width: CGFloat = 128, appearance: NSAppearance.Name = .darkAqua,
                          name: String = "DSC_0042.jpg") -> (ThumbnailItem, NSWindow) {
        let item = ThumbnailItem()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        windows.append(window)
        item.view.frame = NSRect(x: 20, y: 20, width: width, height: width + 40)
        window.contentView?.addSubview(item.view)
        item.configure(with: browserItem(name), pixelSize: Int(width),
                       cache: ShrikeServices.makeDefault().thumbnailCache)
        redraw(item)
        return (item, window)
    }

    private func browserItem(_ name: String) -> BrowserItem {
        BrowserItem(url: dir.appendingPathComponent(name), displayName: name, fileSize: 1,
                    modificationDate: Date(), creationDate: nil, captureDate: nil, utType: .jpeg,
                    pixelWidth: nil, pixelHeight: nil, rating: 0)
    }

    private func redraw(_ item: ThumbnailItem) {
        item.view.layoutSubtreeIfNeeded()
        item.view.needsDisplay = true
        item.view.displayIfNeeded()
    }

    private func resolved(_ color: NSColor, _ item: ThumbnailItem) -> CGColor {
        color.resolvedCGColor(for: item.view.effectiveAppearance)
    }

    private func rgb(_ color: CGColor?) -> [Int] {
        guard let c = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return [] }
        return comps.prefix(3).map { Int(($0 * 255).rounded()) }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    // MARK: Selected, window key

    func testSelectedCellHasAnAccentRingOutsideTheCardAndACapsule() {
        let (item, _) = makeCell()
        item.isKeyOverrideForTesting = true
        var drawn = item.drawnForTesting
        XCTAssertEqual(drawn.ringWidth, 0, "no ring when not selected")
        XCTAssertFalse(drawn.capsuleShown)

        item.isSelected = true
        redraw(item)
        drawn = item.drawnForTesting
        XCTAssertEqual(drawn.ringWidth, 3)
        XCTAssertEqual(drawn.ring, resolved(ShrikeAccent.mark, item))
        XCTAssertTrue(drawn.capsuleShown)
        XCTAssertEqual(drawn.capsule, resolved(.selectedContentBackgroundColor, item))
        XCTAssertEqual(drawn.text, .alternateSelectedControlTextColor)

        let g = item.geometryForTesting
        XCTAssertEqual(g.ring, g.card.insetBy(dx: -3, dy: -3), "ring 3 pt outside the card")
        XCTAssertTrue(item.view.bounds.contains(g.ring), "the ring stays inside the cell")
        XCTAssertEqual(g.capsule.height, 18)
        XCTAssertLessThanOrEqual(g.capsule.width, item.view.bounds.width, "max width = cell width")
        XCTAssertEqual(ThumbnailItem.cardRadius, 10)
        XCTAssertEqual(ThumbnailItem.ringRadius, 13)
        XCTAssertEqual(item.nameFontForTesting?.pointSize, 12)
    }

    func testALongNameTruncatesInsideTheCapsule() {
        let (item, _) = makeCell(width: 96, name: "A_very_long_file_name_from_a_camera_0001.jpg")
        item.isKeyOverrideForTesting = true
        item.isSelected = true
        redraw(item)
        let g = item.geometryForTesting
        XCTAssertLessThanOrEqual(g.capsule.width, 96)
        XCTAssertGreaterThanOrEqual(g.capsule.minX, 0)
    }

    // MARK: Window not key

    func testWindowNotKeyTurnsTheRingAndCapsuleGrey() {
        let (item, window) = makeCell()
        item.isSelected = true
        item.isKeyOverrideForTesting = false
        redraw(item)
        let drawn = item.drawnForTesting
        XCTAssertEqual(drawn.ring, resolved(.unemphasizedSelectedContentBackgroundColor, item))
        XCTAssertEqual(drawn.capsule, resolved(.unemphasizedSelectedContentBackgroundColor, item))
        XCTAssertEqual(drawn.text, .labelColor)

        // Key changes of the cell's own window redraw it. (`needsDisplay`
        // reads false on layer-backed views, so count colour passes.)
        item.view.displayIfNeeded()
        let passes = item.colorPassesForTesting
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        item.view.displayIfNeeded()
        XCTAssertEqual(item.colorPassesForTesting, passes + 1)

        // Another window's key change is ignored.
        var fired = 0
        let probe = LiveColorObserver(view: item.view) { fired += 1 }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        XCTAssertEqual(fired, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(fired, 1)
        withExtendedLifetime(probe) {}
    }

    // MARK: Accent colour change

    func testSystemColourChangeRedrawsWithTheLiveAccent() {
        let (item, _) = makeCell()
        item.isKeyOverrideForTesting = true
        item.isSelected = true
        redraw(item)
        let passes = item.colorPassesForTesting
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        item.view.displayIfNeeded()
        XCTAssertEqual(item.colorPassesForTesting, passes + 1, "accent change redraws without reselecting")
        // The look names the dynamic system colour; it resolves at draw time.
        XCTAssertEqual(item.currentLook.ring, ShrikeAccent.mark)
    }

    // MARK: Light / Dark

    func testLightDarkSwitchRecoloursTheCardAtOnce() {
        let (item, window) = makeCell(appearance: .aqua)
        XCTAssertEqual(rgb(item.drawnForTesting.card), [0xE8, 0xE8, 0xEB], "surface.sunken light")
        window.appearance = NSAppearance(named: .darkAqua)
        item.view.displayIfNeeded()
        XCTAssertEqual(rgb(item.drawnForTesting.card), [0x0F, 0x0F, 0x11], "surface.sunken dark")
    }

    func testGridBackgroundIsSurfaceBase() {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        XCTAssertEqual(content.gridBackgroundForTesting, ShrikeTokens.surfaceBase)
    }

    func testIncreaseContrastAddsAOnePointBorderOnEveryCard() {
        ShrikeTokens.increaseContrastOverride = true
        let (item, _) = makeCell()
        XCTAssertEqual(item.drawnForTesting.cardBorder, 1)
        item.isKeyOverrideForTesting = true
        item.isSelected = true
        redraw(item)
        XCTAssertEqual(item.drawnForTesting.ringWidth, 3, "ring stays 3 pt")
        XCTAssertEqual(item.currentLook.border, .separatorColor)
    }

    // MARK: Decode failure

    private func writeTruncatedJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (data as Data).prefix(24).write(to: dir.appendingPathComponent(name))
    }

    func testTruncatedJPEGShowsTheTriangleAndTextOnlyOnBigCells() async throws {
        try writeTruncatedJPEG("DSC_0042.jpg")
        let (big, _) = makeCell(width: 128)
        let failed = await waitUntil { big.isFailed }
        XCTAssertTrue(failed, "the decode error is no longer swallowed")
        big.view.needsLayout = true
        big.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(big.failureShownForTesting.icon)
        XCTAssertTrue(big.failureShownForTesting.text, "\"Can't preview\" at 128 pt")
        XCTAssertEqual(big.view.accessibilityLabel(), "DSC_0042.jpg, can't preview")
        XCTAssertEqual(big.view.toolTip, "Shrike can't read this file.")

        let (small, _) = makeCell(width: 64)
        let smallFailed = await waitUntil { small.isFailed }
        XCTAssertTrue(smallFailed)
        small.view.needsLayout = true
        small.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(small.failureShownForTesting.icon)
        XCTAssertFalse(small.failureShownForTesting.text, "triangle only at 64 pt")

        // Reuse clears the failure.
        big.prepareForReuse()
        XCTAssertFalse(big.failureShownForTesting.icon)
        XCTAssertNil(big.view.toolTip)
    }

    // MARK: VoiceOver (spec 25 §7.3)

    func testCellIsOneElementWithWordsAndSelectedState() {
        let (item, _) = makeCell(name: "IMG_4222.JPG")
        item.applyBadges(ItemBadges(rating: 3, flagged: true))
        XCTAssertEqual(item.view.accessibilityLabel(), "IMG_4222.JPG, 3 stars, flagged")
        XCTAssertTrue(item.view.accessibilityChildren()?.isEmpty ?? true)
        XCTAssertTrue(item.view.isAccessibilityElement())
        XCTAssertFalse(item.view.isAccessibilitySelected())
        item.isSelected = true
        XCTAssertTrue(item.view.isAccessibilitySelected())
        item.applyBadges(ItemBadges(rating: 1))
        XCTAssertEqual(item.view.accessibilityLabel(), "IMG_4222.JPG, 1 star")
    }

    // MARK: Hover

    func testHoverChangesNoPixel() {
        let (item, _) = makeCell()
        // The tooltip adds AppKit-owned tracking areas; the cell adds none of its own.
        XCTAssertTrue(item.view.trackingAreas.filter { $0.owner === item.view || $0.owner === item }.isEmpty,
                      "no hover tracking on a cell")
        XCTAssertTrue(CATransform3DIsIdentity(item.view.layer?.transform ?? CATransform3DIdentity), "no hover scale")
    }
}

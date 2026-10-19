import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class HUDOverlayReadabilityTests: XCTestCase {
    private var root: URL!
    private var savedReview = false, savedLarge = false, savedStrip = false, savedPin = false
    private var savedMotion: Bool?
    private var windows: [NSWindow] = []
    private var contents: [ViewerContentView] = []
    private var caches: [ThumbnailCache] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-overlay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedReview = Prefs.reviewControlsVisible; savedLarge = Prefs.largerChrome
        savedStrip = Prefs.filmstripVisibleInWindowed; savedPin = Prefs.filmstripPinnedFullscreen
        savedMotion = ReduceMotion.overrideForTesting; ReduceMotion.overrideForTesting = true
        Prefs.reviewControlsVisible = false; Prefs.largerChrome = false
        Prefs.filmstripVisibleInWindowed = false; Prefs.filmstripPinnedFullscreen = false
        ViewerContentView.resetTeachOnceForTesting(taught: true)
    }
    override func tearDown() async throws {
        for content in contents { content.editModeController.releaseAfterClose() }
        for window in windows { window.close() }
        contents = []; windows = []
        for cache in caches { await cache.waitForPendingDiskWrites(); await cache.evictMemory() }
        Prefs.reviewControlsVisible = savedReview; Prefs.largerChrome = savedLarge
        Prefs.filmstripVisibleInWindowed = savedStrip; Prefs.filmstripPinnedFullscreen = savedPin
        ReduceMotion.overrideForTesting = savedMotion
        try? FileManager.default.removeItem(at: root)
    }
    private func services(store: MetadataStore? = nil) throws -> ShrikeServices {
        let cache = try ThumbnailCache(diskURL: root.appendingPathComponent(UUID().uuidString)); caches.append(cache)
        return ShrikeServices(thumbnailCache: cache, metadataStore: try store ?? MetadataStore(databaseURL: root.appendingPathComponent("\(UUID()).sqlite"), writeFileAttributes: { false }))
    }
    private func makeContent(width: CGFloat, services: ShrikeServices? = nil) throws -> ViewerContentView {
        let content = ViewerContentView(services: try services ?? self.services())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content; content.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        windows.append(window); contents.append(content)
        content.imageView.setImage(SaveFlowTests.image(width: 1600, height: 1000, red: 1), sourceID: "bright-photo")
        settle(content)
        return content
    }
    private func settle(_ content: ViewerContentView) {
        for _ in 0..<3 { content.needsLayout = true; content.layoutSubtreeIfNeeded() }
    }
    private func assertOpaque(_ surface: HUDSurfaceView, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(surface.look, .solid, file: file, line: line)
        XCTAssertTrue(surface.usesOpaqueFill, file: file, line: line)
        let fill = try XCTUnwrap(surface.fillLayerForTesting?.backgroundColor, file: file, line: line)
        XCTAssertEqual(fill.alpha, 1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(surface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, file: file, line: line)
    }
    func testReviewFitsMinimumAndNormalWidthsInBothAppearancesWithLiveLargeText() throws {
        Prefs.reviewControlsVisible = true
        for width: CGFloat in [480, 800] {
            let content = try makeContent(width: width)
            let view = content.imageView
            let initialRect = view.displayedImageRectForTesting
            content.installReviewControls(); settle(content)
            XCTAssertEqual(view.displayedImageRectForTesting, initialRect)
            for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
                content.windowMode = mode
                if mode == .fullscreen { content.evaluateZonesForTesting(at: NSPoint(x: width / 2, y: 1)) }
                settle(content)
                let imageRect = view.displayedImageRectForTesting, pixelScale = view.pixelScale
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    content.appearance = NSAppearance(named: appearance)
                    for large in [false, true] {
                        Prefs.largerChrome = large
                        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                        settle(content)
                        let row = content.reviewControls
                        XCTAssertEqual(content.bounds.width, width, "Review must never widen the photo canvas")
                        XCTAssertFalse(row.isHidden); try assertOpaque(row)
                        XCTAssertEqual(row.isFullScreenHUD, mode == .fullscreen)
                        XCTAssertLessThanOrEqual(row.frame.maxX, content.bounds.maxX - 8.0 + 0.1)
                        XCTAssertGreaterThanOrEqual(row.frame.minX, 8.0 - 0.1)
                        for button in row.buttons {
                            XCTAssertTrue(row.contentHost.bounds.insetBy(dx: 7, dy: 7).contains(button.frame), "\(button.title), width \(width), Large \(large): \(button.frame) in \(row.bounds)")
                            XCTAssertGreaterThanOrEqual(button.frame.width, ceil(button.fittingSize.width))
                            XCTAssertGreaterThanOrEqual(button.frame.height, ChromeTypography.targetHeight)
                            XCTAssertEqual(button.font?.pointSize, ChromeTypography.size(12))
                            let point = row.contentHost.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: row.superview)
                            let hit = row.hitTest(point)
                            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
                        }
                        if width == 480 { XCTAssertGreaterThan(Set(row.buttons.map { $0.frame.minY }).count, 1) }
                        XCTAssertEqual(view.displayedImageRectForTesting, imageRect); XCTAssertEqual(view.pixelScale, pixelScale)
                        XCTAssertEqual(view.sourceID, "bright-photo")
                    }
                }
            }
        }
    }
    func testWideReviewStaysOneRowAndNativeActionsAndKeyOrderSurviveWrapping() throws {
        Prefs.reviewControlsVisible = true
        let content = try makeContent(width: 1400); content.installReviewControls(); settle(content)
        let row = content.reviewControls
        XCTAssertEqual(Set(row.buttons.map { $0.frame.minY }).count, 1)
        var navigation: [Bool] = [], ratings: [Int] = [], flags = 0
        row.onNavigate = { navigation.append($0) }; row.onRate = { ratings.append($0) }; row.onFlag = { flags += 1 }
        for button in row.buttons.dropLast() { button.performClick(nil) }
        XCTAssertEqual(navigation, [false, true]); XCTAssertEqual(ratings, [1, 2, 3, 4, 5, 0]); XCTAssertEqual(flags, 1)
        for (button, next) in zip(row.buttons, row.buttons.dropFirst()) { XCTAssertTrue(button.nextKeyView === next) }
        XCTAssertFalse(row.acceptsFirstResponder)
        row.update(record: FileRecord(rating: 3, flagged: true), durable: false)
        XCTAssertEqual(row.buttons.first { $0.title == "3★" }?.state, .on)
        XCTAssertEqual(row.buttons.first { $0.title == "Flag" }?.state, .on)
        XCTAssertEqual(row.buttons.last?.isEnabled, false)
    }
    func testReviewWholeSurfaceVisibilityTracksOptInEditAndFullscreenBottomZone() throws {
        let content = try makeContent(width: 800)
        XCTAssertFalse(content.subviews.contains { $0 is ReviewControls })
        Prefs.reviewControlsVisible = true; content.installReviewControls(); settle(content)
        XCTAssertFalse(content.reviewControls.isHidden)
        Prefs.reviewControlsVisible = false; content.refreshReviewVisibility(); XCTAssertTrue(content.reviewControls.isHidden)
        Prefs.reviewControlsVisible = true; content.refreshReviewVisibility()
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: nil)
        XCTAssertTrue(content.reviewControls.isHidden)
        content.editModeController.finalizeExit()
        XCTAssertFalse(content.reviewControls.isHidden)
        content.cursorLocationOverrideForTesting = NSPoint(x: 400, y: 320)
        content.windowMode = .fullscreen; content.fireTeachOnceExpiryForTesting()
        content.evaluateZonesForTesting(at: NSPoint(x: 400, y: 320))
        content.forceExitGraceFireForTesting(.filmstrip); settle(content)
        XCTAssertTrue(content.reviewControls.isHidden)
        content.evaluateZonesForTesting(at: NSPoint(x: 400, y: 1)); settle(content)
        XCTAssertFalse(content.reviewControls.isHidden); XCTAssertTrue(content.reviewControls.isFullScreenHUD)
        try assertOpaque(content.reviewControls)
        content.evaluateZonesForTesting(at: NSPoint(x: 400, y: 320)); content.forceExitGraceFireForTesting(.filmstrip); settle(content)
        XCTAssertTrue(content.reviewControls.isHidden)
    }
    func testFullscreenReviewClearsHoveredAndPinnedBottomStack() throws {
        Prefs.reviewControlsVisible = true
        let content = try makeContent(width: 800); content.installReviewControls()
        content.cursorLocationOverrideForTesting = NSPoint(x: 400, y: 320)
        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: NSPoint(x: 400, y: 1)); settle(content)
        let row = content.reviewControls
        XCTAssertFalse(row.isHidden)
        XCTAssertGreaterThanOrEqual(row.frame.minY, content.capsuleFrameForTesting.maxY + 8)
        content.togglePanel(.filmstrip)
        content.evaluateZonesForTesting(at: NSPoint(x: 400, y: 320))
        content.forceExitGraceFireForTesting(.toolbar); content.forceExitGraceFireForTesting(.filmstrip); settle(content)
        XCTAssertTrue(content.isPinnedForTesting(.filmstrip)); XCTAssertFalse(row.isHidden)
        XCTAssertGreaterThanOrEqual(row.frame.minY, content.filmstripForTesting.frame.maxY + 8)
        let pinnedBottom = row.frame.minY
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil); settle(content)
        XCTAssertEqual(row.frame.minY, pinnedBottom)
        content.togglePanel(.filmstrip); settle(content)
        XCTAssertTrue(row.isHidden)
    }
    func testViewerPersistenceSurfaceHidesAfterActualStorageRecovery() async throws {
        let blocked = root.appendingPathComponent("blocked"); try Data([1]).write(to: blocked)
        let primary = blocked.appendingPathComponent("ratings.sqlite")
        let store = MetadataStore.openWithFallback(primary: primary, fallback: root.appendingPathComponent("fallback.sqlite"))
        let content = try makeContent(width: 480, services: services(store: store))
        let banner = PersistenceBanner(store: store); defer { banner.dispose() }
        content.installPersistenceBanner(banner); settle(content)
        let surface = try XCTUnwrap(content.persistenceSurface)
        XCTAssertFalse(surface.isHidden); try assertOpaque(surface)
        XCTAssertTrue(banner.isDescendant(of: surface.contentHost))
        for width: CGFloat in [480, 800] {
            content.window?.setContentSize(NSSize(width: width, height: 640))
            for large in [false, true] {
                Prefs.largerChrome = large; NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    content.appearance = NSAppearance(named: appearance)
                    for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
                        content.windowMode = mode; settle(content)
                        XCTAssertEqual(content.bounds.width, width, "Storage warning must not widen the canvas")
                        XCTAssertFalse(surface.isHidden); try assertOpaque(surface)
                        XCTAssertEqual(surface.isFullScreenHUD, mode == .fullscreen)
                        XCTAssertTrue(surface.contentHost.bounds.contains(banner.frame))
                        for child in banner.arrangedSubviews {
                            XCTAssertTrue(banner.bounds.contains(child.frame), "Storage action/text is clipped: \(child.frame) in \(banner.bounds)")
                            if let button = child as? NSButton {
                                XCTAssertGreaterThanOrEqual(button.bounds.width, button.fittingSize.width)
                                XCTAssertEqual(button.font?.pointSize, ChromeTypography.size(12))
                            }
                            if let field = child as? NSTextField, let cell = field.cell {
                                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10000))
                                XCTAssertGreaterThanOrEqual(field.bounds.height + 1, needed.height, "Storage explanation must fully wrap")
                            }
                        }
                    }
                }
            }
        }
        try FileManager.default.removeItem(at: blocked); try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        _ = try await store.retryPersistentStore(); banner.refresh()
        XCTAssertTrue(surface.isHidden); XCTAssertTrue(banner.isHidden)
    }
    func testEditPolicyOpaqueHostFitsLargeDisclosureAndDisappearsOnExit() async throws {
        let content = try makeContent(width: EditLayout.minCanvasWidth)
        Prefs.largerChrome = true
        let image = SaveFlowTests.image(width: 1600, height: 1000)
        let url = root.appendingPathComponent("disclosure.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        content.enterEditMode(image: image, url: url, landOn: .color)
        await content.editModeController.settleForTesting()
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        settle(content)
        let surface = try XCTUnwrap(content.editSavePolicySurface)
        XCTAssertFalse(surface.isHidden); try assertOpaque(surface)
        let label = try XCTUnwrap(surface.contentHost.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, content.editModeController.chromeState.savePolicy)
        XCTAssertGreaterThan(label.stringValue.count, 50)
        for large in [false, true] {
            Prefs.largerChrome = large
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                content.appearance = NSAppearance(named: appearance)
                for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
                    content.windowMode = mode; settle(content)
                    XCTAssertEqual(content.bounds.width, EditLayout.minCanvasWidth)
                    XCTAssertTrue(surface.contentHost.bounds.contains(label.frame)); XCTAssertGreaterThan(label.bounds.height, 0)
                    XCTAssertEqual(label.font?.pointSize, ChromeTypography.size(12))
                    if let cell = label.cell {
                        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10000))
                        XCTAssertGreaterThanOrEqual(label.bounds.height + 1, needed.height)
                    }
                    XCTAssertLessThanOrEqual(surface.frame.maxX, content.bounds.maxX - EditLayout.columnWidth)
                    XCTAssertEqual(surface.isFullScreenHUD, mode == .fullscreen); try assertOpaque(surface)
                }
            }
        }
        content.editModeController.finalizeExit()
        XCTAssertTrue(surface.isHidden)
    }
}

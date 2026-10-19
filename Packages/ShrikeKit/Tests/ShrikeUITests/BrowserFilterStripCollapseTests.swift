import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserFilterStripCollapseTests: XCTestCase {
    private var savedLarge = false
    override func setUp() async throws { savedLarge = Prefs.largerChrome }
    override func tearDown() async throws { Prefs.largerChrome = savedLarge }
    func testCollapsedAndActiveFilterStripFitsChildrenThroughRepeatedToggles() throws {
        for width: CGFloat in [480, 800] {
            for large in [false, true] {
                Prefs.largerChrome = large
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 320)); window.contentView = host
                let strip = BrowserFilterStrip(); strip.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(strip)
                NSLayoutConstraint.activate([strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    strip.trailingAnchor.constraint(equalTo: host.trailingAnchor), strip.topAnchor.constraint(equalTo: host.topAnchor)])
                let scroll = try XCTUnwrap(strip.subviews.compactMap { $0 as? NSScrollView }.first)
                let active = BrowserFilter(searchTerm: "Bright")
                var cleared: BrowserFilter?
                strip.onChange = { cleared = $0 }
                for filter in [BrowserFilter.none, active, .none, active, .none] {
                    strip.show(filter)
                    for _ in 0..<3 { host.needsLayout = true; host.layoutSubtreeIfNeeded() }
                    XCTAssertEqual(host.bounds.width, width)
                    XCTAssertGreaterThanOrEqual(scroll.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(scroll.frame.minY, 0, "Collapsed chrome must not place a child outside its zero-height host")
                    XCTAssertLessThanOrEqual(scroll.frame.maxY, strip.bounds.height)
                    if filter.isEmpty {
                        XCTAssertTrue(strip.isHidden); XCTAssertEqual(strip.bounds.height, 0)
                        XCTAssertEqual(scroll.frame.height, 0)
                    } else {
                        XCTAssertFalse(strip.isHidden)
                        XCTAssertEqual(strip.bounds.height, ChromeTypography.targetHeight + 4)
                        XCTAssertEqual(scroll.frame.minY, 2); XCTAssertEqual(scroll.frame.maxY, strip.bounds.height - 2)
                        let clear = try XCTUnwrap(strip.subviews.compactMap { $0 as? NSButton }.first)
                        XCTAssertTrue(strip.bounds.contains(clear.frame)); clear.performClick(nil)
                        XCTAssertEqual(cleared, BrowserFilter.none)
                    }
                }
            }
        }
    }

    func testProductionBrowserFilterStripStaysBelowToolbarAcrossModesTextSizesAndCollapse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-filter-safe-area-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let thumbs = try ThumbnailCache(diskURL: folder.appendingPathComponent("thumbs", isDirectory: true))
        let metadata = MetadataStore.openWithFallback(primary: folder.appendingPathComponent("metadata.sqlite"), fallback: nil)
        let services = ShrikeServices(thumbnailCache: thumbs, metadataStore: metadata)
        for large in [false, true] {
            Prefs.largerChrome = large
            let browser = BrowserWindowController(services: services, initialFolder: folder)
            defer { browser.close() }
            let window = try XCTUnwrap(browser.window)
            let toolbar = try XCTUnwrap(window.toolbar)
            toolbar.autosavesConfiguration = false
            toolbar.isVisible = true
            window.setFrameAutosaveName("")
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 800), display: false)
            window.orderFront(nil)
            let content = browser.contentController
            let strip = content.filterStrip
            let clear = try XCTUnwrap(strip.subviews.compactMap { $0 as? NSButton }.first)
            for mode in [BrowserViewMode.grid, .list, .filmstrip] {
                content.setMode(mode)
                for active in [false, true, false] {
                    let filter = active ? BrowserFilter(searchTerm: "Bright") : .none
                    browser.searchField.stringValue = filter.searchTerm
                    content.filter = filter
                    for _ in 0..<3 {
                        window.contentView?.superview?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                    XCTAssertTrue(toolbar.isVisible)
                    XCTAssertTrue(browser.searchField.window === window, "Measure the actual mounted production search field")
                    XCTAssertFalse(browser.searchField.isHiddenOrHasHiddenAncestor)
                    let searchRect = browser.searchField.convert(browser.searchField.bounds, to: nil)
                    XCTAssertGreaterThan(searchRect.width, 0)
                    XCTAssertGreaterThan(searchRect.height, 0)
                    let stripRect = strip.convert(strip.bounds, to: nil)
                    let usable = window.contentLayoutRect
                    XCTAssertGreaterThan(window.frame.height, usable.maxY, "The real native toolbar must occupy a band")
                    XCTAssertLessThanOrEqual(stripRect.maxY, usable.maxY + 0.5,
                                             "Filter strip must stay below native toolbar content")
                    XCTAssertEqual(strip.isHidden, !active)
                    XCTAssertEqual(strip.bounds.height, active ? ChromeTypography.targetHeight + 4 : 0)
                    let photoArea: NSView
                    switch mode {
                    case .grid: photoArea = content.gridScrollViewForTesting
                    case .list: photoArea = try XCTUnwrap(content.tableViewForTesting.enclosingScrollView)
                    case .filmstrip: photoArea = try XCTUnwrap(content.view.subviews.compactMap { $0 as? FilmstripPreviewView }.first)
                    }
                    let photoRect = photoArea.convert(photoArea.bounds, to: nil)
                    XCTAssertLessThanOrEqual(photoRect.maxY, stripRect.minY + 0.5,
                                             "Photo content follows the filter strip in every Browser mode")
                    if active {
                        let clearRect = clear.convert(clear.bounds, to: nil)
                        XCTAssertLessThanOrEqual(clearRect.maxY, usable.maxY + 0.5,
                                                 "Clear All must stay below native toolbar content")
                        XCTAssertFalse(clearRect.intersects(searchRect), "Clear All must not overlap the production toolbar search field")
                        XCTAssertGreaterThanOrEqual(searchRect.minY, clearRect.maxY - 0.5)
                        clear.performClick(nil)
                        XCTAssertEqual(content.filter, .none)
                        XCTAssertEqual(browser.currentFilterForTesting, .none)
                        XCTAssertEqual(browser.searchField.stringValue, "")
                        window.contentView?.superview?.layoutSubtreeIfNeeded()
                        XCTAssertTrue(strip.isHidden)
                        XCTAssertEqual(strip.bounds.height, 0)
                    }
                }
            }
        }
    }

}

//
//  ShareMenuTests.swift
//  ShrikeUITests
//
//  Share ▸ is a working
//  submenu of system share services in the File menu and the viewer's
//  and Browser's right-click menus. It shares the photo on screen with
//  its RAW sibling, or the Browser selection; with nothing to share it
//  is a disabled "Share" row.
//

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ShareMenuTests: XCTestCase {

    private var dir: URL!
    private var shared: [[URL]] = []
    private var savedProvider: (([URL]) -> [NSSharingService])!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        shared = []
        savedProvider = ShareSubmenu.servicesProvider
        // One fake service that records what it was given.
        ShareSubmenu.servicesProvider = { [weak self] _ in
            [NSSharingService(title: "Test Service", image: NSImage(size: NSSize(width: 16, height: 16)),
                              alternateImage: nil) { self?.shared.append([]) }]
        }
    }

    override func tearDown() async throws {
        ShareSubmenu.servicesProvider = savedProvider
        try? FileManager.default.removeItem(at: dir)
    }

    private final class StubTarget: ShrikeCommandTarget {
        var urls: [URL] = []
        func canPerform(_ command: ShrikeCommand) -> Bool { true }
        func perform(_ command: ShrikeCommand) {}
        func menuState(for command: ShrikeCommand) -> NSControl.StateValue { .off }
        var commandFileURLs: [URL] { urls }
    }

    private func pair() throws -> ImageGroup {
        let jpg = dir.appendingPathComponent("P1.JPG")
        try SaveFlowTests.writeImage(jpg, type: .jpeg)
        let raw = dir.appendingPathComponent("P1.ORF")
        try Data([0]).write(to: raw)
        let xmp = dir.appendingPathComponent("P1.xmp")
        return ImageGroup(primary: jpg, companions: [.init(url: raw, kind: .raw), .init(url: xmp, kind: .sidecar)])
    }

    func testGroupFilesAreThePhotoAndItsRAW() throws {
        let group = try pair()
        XCTAssertEqual(ShareSubmenu.files(of: group).map(\.lastPathComponent), ["P1.JPG", "P1.ORF"],
                       "sidecars are not shared")
    }

    func testFileMenuShareIsASubmenuOfServices() {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let stub = StubTarget()
        bar.mainTarget = { stub }
        bar.menuNeedsUpdate(bar.fileMenu)
        let row = try? XCTUnwrap(bar.items(for: .share).first)
        XCTAssertEqual(row?.title, "Share")
        XCTAssertEqual(row?.isEnabled, false, "nothing to share")
        XCTAssertNil(row?.submenu)
        XCTAssertTrue(bar.fileMenu.items.contains { $0 === row }, "the row stays in the File menu")

        stub.urls = [dir.appendingPathComponent("a.jpg")]
        bar.menuNeedsUpdate(bar.fileMenu)
        XCTAssertEqual(row?.isEnabled, true)
        let sub = row?.submenu
        XCTAssertNotNil(sub, "Share ▸ is a submenu")
        XCTAssertEqual(sub?.items.count, 0, "services are listed only when the submenu opens")
        if let sub { sub.delegate?.menuNeedsUpdate?(sub) }   // the submenu opens
        XCTAssertEqual(sub?.items.map(\.title), ["Test Service"])
        let service = try? XCTUnwrap(sub?.items.first)
        XCTAssertNotNil(service?.image)
        XCTAssertNotNil(service?.action)
        XCTAssertTrue(service?.target === bar.shareSubmenu)
    }

    /// The real system list for a JPEG is not empty (AirDrop, Mail…).
    func testSystemProviderListsServicesForAJPEG() throws {
        let url = dir.appendingPathComponent("s.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        XCTAssertFalse(savedProvider([url]).isEmpty)
    }

    func testViewerRightClickSharesThePhotoAndItsRAW() throws {
        let group = try pair()
        let viewer = ViewerWindow(groups: [group], startIndex: 0, services: .makeDefault())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        XCTAssertEqual(viewer.shareFileURLs.map(\.lastPathComponent), ["P1.JPG", "P1.ORF"])
        let menu = viewer.contextMenu.menu
        viewer.contextMenu.menuNeedsUpdate(menu)
        let row = try XCTUnwrap(menu.items.first { $0.title == "Share" })
        XCTAssertTrue(row.isEnabled)
        let sub = try XCTUnwrap(row.submenu)
        sub.delegate?.menuNeedsUpdate?(sub)
        let service = try XCTUnwrap(sub.items.first)
        XCTAssertEqual(service.title, "Test Service")
        let request = try XCTUnwrap(service.representedObject as? ShareRequest)
        XCTAssertEqual(request.urls.map(\.lastPathComponent), ["P1.JPG", "P1.ORF"])
        // Choosing the row runs the service.
        _ = (service.target as? NSObject)?.perform(service.action, with: service)
        XCTAssertEqual(shared.count, 1)
    }

    func testBrowserRightClickSharesTheSelection() throws {
        let group = try pair()
        let content = BrowserContentViewController(services: .makeDefault())
        _ = content.view
        var item = BrowserItem(url: group.primary, displayName: "P1.JPG", fileSize: 1,
                               modificationDate: Date(), utType: .jpeg)
        item.group = group
        let other = BrowserItem(url: dir.appendingPathComponent("b.jpg"), displayName: "b.jpg", fileSize: 1,
                                modificationDate: Date(), utType: .jpeg)
        content.setItems([item, other])
        let share = try XCTUnwrap(content.shareSubmenus.first)
        let row = try XCTUnwrap(share.parentItem)
        let parentMenu = try XCTUnwrap(row.menu)

        share.menuNeedsUpdate(parentMenu)
        XCTAssertFalse(row.isEnabled, "nothing selected: disabled")
        XCTAssertNil(row.submenu)

        XCTAssertTrue(content.select(urls: [group.primary, other.url]))
        share.menuNeedsUpdate(parentMenu)
        XCTAssertTrue(row.isEnabled)
        let sub = try XCTUnwrap(row.submenu)
        share.menuNeedsUpdate(sub)
        let request = try XCTUnwrap(sub.items.first?.representedObject as? ShareRequest)
        XCTAssertEqual(Set(request.urls.map(\.lastPathComponent)), ["P1.JPG", "P1.ORF", "b.jpg"],
                       "the whole selection, each photo with its RAW")
    }
}

//
//  OpenFolderReuseTests.swift
//  ShrikeUITests
//
//  Spec 25 §4: a folder that is already open in a Browser is brought
//  forward, not opened a second time.
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class OpenFolderReuseTests: XCTestCase {

    private var root: URL!
    private var coordinator: WindowCoordinator!
    private var services: ShrikeServices!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-reuse-\(UUID().uuidString)", isDirectory: true)
        for name in ["X", "X/Y", "Z"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data([0]).write(to: root.appendingPathComponent("X/a.jpg"))
        coordinator = WindowCoordinator()
        services = ShrikeServices.makeDefault()
        coordinator.services = services
    }

    override func tearDown() async throws {
        for browser in coordinator.browsers { browser.close() }
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    // Vector 1
    func testOpeningTheSameFolderTwiceMakesOneBrowser() {
        coordinator.openFolders([folder("X")])
        coordinator.openFolders([folder("X")])
        XCTAssertEqual(coordinator.browsers.count, 1)
    }

    // Vector 2
    func testAMinimizedBrowserComesBack() throws {
        coordinator.openFolders([folder("X")])
        let browser = try XCTUnwrap(coordinator.browsers.first)
        XCTAssertTrue(coordinator.browser(showing: folder("X")) === browser)
        coordinator.openFolders([folder("X")])
        XCTAssertEqual(coordinator.browsers.count, 1)
    }

    // Vector 3
    func testTwoFoldersOneAlreadyOpenMakesOneNewWindow() {
        coordinator.openFolders([folder("X")])
        coordinator.openFolders([folder("X"), folder("Z")])
        XCTAssertEqual(coordinator.browsers.count, 2)
    }

    // Vector 4
    func testNewBrowserWindowAlwaysMakesAnother() {
        coordinator.newBrowserWindow()
        coordinator.newBrowserWindow()
        XCTAssertEqual(coordinator.browsers.count, 2)
    }

    // Vector 5
    func testSelectingAFileInTheExistingBrowser() throws {
        let existing = coordinator.openBrowser(at: folder("X"), selecting: nil, services: services)
        let again = coordinator.openBrowser(at: folder("X"), selecting: folder("X").appendingPathComponent("a.jpg"),
                                            services: services)
        XCTAssertTrue(existing === again)
        XCTAssertEqual(coordinator.browsers.count, 1)
    }

    // Vector 6
    func testABrowserThatWentIntoASubfolderDoesNotCount() {
        let first = coordinator.openBrowser(at: folder("X"), selecting: nil, services: services)
        first.navigate(to: folder("X/Y"))
        XCTAssertNil(coordinator.browser(showing: folder("X")))
        let second = coordinator.openBrowser(at: folder("X"), selecting: nil, services: services)
        XCTAssertFalse(first === second)
        XCTAssertEqual(coordinator.browsers.count, 2)
    }

    func testTheFourFolderLimitCountsOnlyNewWindows() {
        let names = ["A", "B", "C", "D", "E"]
        for name in names { try? FileManager.default.createDirectory(at: folder(name), withIntermediateDirectories: true) }
        coordinator.openFolders([folder("X")])
        coordinator.openFolders([folder("X")] + names.map(folder))
        XCTAssertEqual(coordinator.browsers.count, 1 + 4, "X reused; four of the five new ones opened")
    }
}

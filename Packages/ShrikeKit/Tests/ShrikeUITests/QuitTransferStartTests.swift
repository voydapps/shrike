//
//  QuitTransferStartTests.swift
//  ShrikeUITests
//
//  Pass 2k Q1 (28a round 7): ⌘Q right after the user started a copy quit
//  at once and nothing was copied. A copy / move counts as running for
//  the quit plan from the moment the user starts it (destination chosen,
//  a drop, a menu item), also while it still waits for the window's
//  earlier work; it leaves the running list on every exit.
//

import XCTest
import AppKit
import os
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class QuitTransferStartTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var selects: URL!
    private var released = false

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-quit-start-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Shoot", isDirectory: true)
        selects = root.appendingPathComponent("Selects", isDirectory: true)
        for folder in [dir!, selects!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        released = false
    }

    override func tearDown() async throws {
        released = true
        await expect("no reservation is left behind") { FileTransferCoordinator.running.isEmpty }
        try? FileManager.default.removeItem(at: root)
    }

    private func viewer(_ name: String = "a.jpg") throws -> (ViewerWindow, URL) {
        let url = dir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil)
        viewer.transfers.slots = DestinationSlots(defaults: makeTestDefaults())
        viewer.markDisplayedForTesting(0)
        return (viewer, url)
    }

    /// The window's earlier work (a trash, a rename) that the copy waits for.
    private func holdChain(_ viewer: ViewerWindow) {
        viewer.trashChain = Task { @MainActor [weak self] in
            while self?.released == false { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func expect(_ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                        _ condition: () -> Bool) async {
        let ok = await waitUntil(3, condition)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testTransferCountsAsRunningInTheSameTurnItStarts() async throws {
        let (viewer, url) = try viewer()
        defer { viewer.close() }
        holdChain(viewer)
        viewer.transfer(.copy, ImageGroup(primary: url), to: selects)
        // No await in between: ⌘Q in the very next event must ask.
        let coordinator = WindowCoordinator()
        XCTAssertEqual(coordinator.quitPlan, .later)
        XCTAssertEqual(coordinator.runningWork().transfers, [QuitWork.Transfer(verb: .copy, completed: 0, total: 1)])
        released = true
        await expect { FileTransferCoordinator.running.isEmpty }
        XCTAssertTrue(exists(selects.appendingPathComponent("a.jpg")))
        XCTAssertEqual(coordinator.quitPlan, .now, "after completion nothing runs")
    }

    func testPanelChoiceCountsAsRunningAtOnce() async throws {
        let (viewer, _) = try viewer()
        defer { viewer.close() }
        holdChain(viewer)
        var asked = false
        let target = selects!
        viewer.transfers.panelResponder = { _ in asked = true; return target }
        XCTAssertTrue(FileTransferCoordinator.running.isEmpty, "the panel is not open yet")
        viewer.fileToFolder(.move, .choose)
        await expect { asked }
        XCTAssertEqual(FileTransferCoordinator.runningWork, [QuitWork.Transfer(verb: .move, completed: 0, total: 1)])
        XCTAssertEqual(WindowCoordinator().quitPlan, .later)
        released = true
        await expect { FileTransferCoordinator.running.isEmpty }
    }

    func testCancelledPanelLeavesNothingRunning() async throws {
        let (viewer, _) = try viewer()
        defer { viewer.close() }
        var asked = false
        viewer.transfers.panelResponder = { _ in asked = true; return nil }
        viewer.fileToFolder(.copy, .choose)
        await expect { asked }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FileTransferCoordinator.running.isEmpty)
        XCTAssertEqual(WindowCoordinator().quitPlan, .now)
    }

    func testAlreadyInTheFolderLeavesNothingRunning() async throws {
        let (viewer, url) = try viewer()
        defer { viewer.close() }
        viewer.transfer(.copy, ImageGroup(primary: url), to: dir)
        XCTAssertTrue(FileTransferCoordinator.running.isEmpty)
    }

    /// Quit Anyway while the copy still waits: nothing is copied and the
    /// quit has nothing left to wait on.
    func testStopWhileWaitingCopiesNothing() async throws {
        let (viewer, url) = try viewer()
        defer { viewer.close() }
        holdChain(viewer)
        viewer.transfer(.copy, ImageGroup(primary: url), to: selects)
        FileTransferCoordinator.stopAllRunning()
        released = true
        await expect { FileTransferCoordinator.running.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(exists(selects.appendingPathComponent("a.jpg")))
        XCTAssertTrue(exists(url))
    }

    /// The Browser reserves the same way (drops and the sidebar call `transfer`).
    func testReservationReleaseIsSafeTwice() async throws {
        let (_, url) = try viewer("b.jpg")
        let reservation = FileTransferCoordinator.reserve(.copy, total: 3)
        XCTAssertEqual(FileTransferCoordinator.runningWork, [QuitWork.Transfer(verb: .copy, completed: 0, total: 3)])
        FileTransferCoordinator.release(reservation)
        FileTransferCoordinator.release(reservation)
        XCTAssertTrue(FileTransferCoordinator.running.isEmpty, "release is safe twice")
        _ = url
    }

    /// 28a round 8: ~2 s of no reaction after Choose for 2000 photos. The
    /// Browser's transfer reserves with the selection count and does no
    /// "already in this folder" disk check on the calling path.
    func testBrowserTransferDoesNoDiskCheckOnTheCallingPath() async throws {
        let urls = try (0..<3).map { i -> URL in
            let url = dir.appendingPathComponent("p\(i).jpg")
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            return url
        }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        browser.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil)
        browser.transfers.slots = DestinationSlots(defaults: makeTestDefaults())
        let calls = CallCounter()
        browser.transfer(.copy, urls.map { ImageGroup(primary: $0) }, to: selects) { url in
            calls.add()
            return GroupList.canonical(url)
        }
        XCTAssertEqual(calls.count, 0, "no disk check on the calling path")
        XCTAssertEqual(FileTransferCoordinator.runningWork, [QuitWork.Transfer(verb: .copy, completed: 0, total: 3)])
        released = true
        await expect { FileTransferCoordinator.running.isEmpty }
        XCTAssertEqual(calls.count, 2, "once for the folder, once for the one parent folder")
        for url in urls { XCTAssertTrue(exists(selects.appendingPathComponent(url.lastPathComponent))) }
    }

    /// Already in the folder by its plain path: answered at once, nothing reserved.
    func testBrowserAlreadyInTheFolderLeavesNothingRunning() async throws {
        let url = dir.appendingPathComponent("q.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        browser.transfer(.copy, [ImageGroup(primary: url)], to: dir) { _ in
            XCTFail("no disk check")
            return ""
        }
        XCTAssertTrue(FileTransferCoordinator.running.isEmpty)
    }

    func testTransferWorkResolvesEachParentOnce() {
        let groups = ["/a/x/1.jpg", "/a/x/2.jpg", "/a/y/3.jpg"].map { ImageGroup(primary: URL(fileURLWithPath: $0)) }
        var seen: [String] = []
        let work = BrowserWindowController.transferWork(groups, to: URL(fileURLWithPath: "/a/link")) { url in
            seen.append(url.path)
            return url.path == "/a/link" ? "/a/y" : url.path
        }
        XCTAssertEqual(work.map(\.primary.lastPathComponent), ["1.jpg", "2.jpg"])
        XCTAssertEqual(seen, ["/a/link", "/a/x", "/a/y"])
    }
}

/// Counts calls from any thread.
private final class CallCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    func add() { state.withLock { $0 += 1 } }
    var count: Int { state.withLock { $0 } }
}

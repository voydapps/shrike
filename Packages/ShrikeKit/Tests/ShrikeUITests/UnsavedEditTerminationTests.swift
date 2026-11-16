//
//  UnsavedEditTerminationTests.swift
//  ShrikeUITests
//
//  While a viewer shows "Unsaved changes", the system may not end the app
//  without the quit question (sudden / automatic termination off). The hold
//  follows the title's own state and is not running work for the quit flow.
//  Counting hooks only: the real ProcessInfo calls are never made here.
//

import AppKit
import os
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

private final class TerminationCounter: Sendable {
    let counts = OSAllocatedUnfairLock(initialState: (disabled: 0, enabled: 0))
    var disabled: Int { counts.withLock { $0.disabled } }
    var enabled: Int { counts.withLock { $0.enabled } }
    func registry() -> ActiveWork {
        ActiveWork(hooks: .init(disable: { self.counts.withLock { $0.disabled += 1 } },
                                enable: { self.counts.withLock { $0.enabled += 1 } }))
    }
}

@MainActor
final class UnsavedEditHoldRegistryTests: XCTestCase {

    func testTwoOwnersMakeOnePairAndTeardownReleases() {
        let counter = TerminationCounter()
        let registry = counter.registry()
        var a: ActiveWorkHold? = ActiveWorkHold(kind: .unsavedEdit, registry: registry)
        let b = ActiveWorkHold(kind: .unsavedEdit, registry: registry)
        a?.set(true); b.set(true); a?.set(true)
        XCTAssertEqual(counter.disabled, 1, "one disable for the first owner only")
        b.set(false); b.set(false)
        XCTAssertEqual(counter.enabled, 0, "the other owner still holds")
        a = nil
        XCTAssertEqual(counter.enabled, 1, "a holder that dies held releases its share")
        XCTAssertTrue(registry.snapshot().isIdle)
    }

    func testUnsavedEditsAreNotSharedWork() {
        XCTAssertFalse(ActiveWork.unsavedEdits === ActiveWork.shared)
        XCTAssertTrue(EditModeController.unsavedEditRegistry === ActiveWork.unsavedEdits)
    }
}

@MainActor
final class UnsavedEditTerminationTests: XCTestCase {

    private var counter: TerminationCounter!
    private var registry: ActiveWork!
    private var root: URL!

    override func setUp() async throws {
        counter = TerminationCounter()
        registry = counter.registry()
        EditModeController.unsavedEditRegistry = registry
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        root = TestScratch.directory.appendingPathComponent("shrike-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        EditModeController.unsavedEditRegistry = .unsavedEdits
        EditToolTransitionModal.responderForTesting = nil
        EditExitModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var held: Bool { registry.snapshot().count(of: .unsavedEdit) == 1 }

    private func assertNotSharedWork(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ActiveWork.shared.snapshot().count(of: .unsavedEdit), 0,
                       "an idle unsaved edit is never running work", file: file, line: line)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testUndoToCleanReleasesAndRedoHoldsAgain() async throws {
        let c = EditModeController()
        c.enter(image: SaveFlowTests.image(width: 400, height: 300), url: nil, landOn: .rotate)
        await c.settleForTesting()
        XCTAssertEqual(counter.disabled, 0, "a clean session holds nothing")
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        XCTAssertEqual(c.chromeState.subtitle, "Editing · Unsaved changes")
        XCTAssertTrue(held); XCTAssertEqual(counter.disabled, 1)
        assertNotSharedWork()
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.chromeState.subtitle, "Editing")
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 1, "undo back to clean releases")
        c.performRedo(); await c.settleForTesting()
        XCTAssertTrue(held); XCTAssertEqual(counter.disabled, 2)
        c.finalizeExit()
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 2, "leaving edit mode releases")
    }

    /// The gap the old hold had: a typed, not applied Resize says "Unsaved
    /// changes" (and the exit question would ask), so it holds too.
    func testTypedResizeDraftHolds() async throws {
        let c = EditModeController()
        c.enter(image: SaveFlowTests.image(width: 400, height: 300), url: nil, landOn: .resize)
        await c.settleForTesting()
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel._widthField.stringValue = "200"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        await c.settleForTesting()
        XCTAssertTrue(c.chromeState.hasPendingToolEdits)
        XCTAssertEqual(c.chromeState.subtitle, "Editing · Unsaved changes")
        XCTAssertTrue(held); XCTAssertEqual(counter.disabled, 1)
        c.finalizeExit()
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 1)
    }

    func testViewerSaveDiscardAndCloseReleaseTheHold() async throws {
        let url = root.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        var services = ShrikeServices.makeDefault()
        services.backupStore = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let c = content.editModeController
        func enterDirty() async throws {
            await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
            content.enterEditMode(image: SaveFlowTests.image(), url: url, landOn: .rotate)
            c.appendSnapped90(quarters: 1); await c.settleForTesting()
            XCTAssertTrue(c.chromeState.hasUnsavedChanges)
        }

        try await enterDirty()
        XCTAssertTrue(held); XCTAssertEqual(counter.disabled, 1)
        assertNotSharedWork()
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 1, "save releases")

        try await enterDirty()
        XCTAssertEqual(counter.disabled, 2)
        EditExitModal.responderForTesting = { _ in .discard }
        let mayQuit = await viewer.resolveUnsavedEditsForQuit()
        XCTAssertTrue(mayQuit)
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 2, "Don't Save releases")

        try await enterDirty()
        XCTAssertEqual(counter.disabled, 3)
        viewer.close()
        XCTAssertFalse(c.isActive)
        XCTAssertFalse(held); XCTAssertEqual(counter.enabled, 3, "a window torn down dirty releases")
    }
}

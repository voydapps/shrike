//
//  SharedPrimitivesTests.swift
//  ShrikeUITests
//
//  Shared primitives: the displayed item and its list,
// the toast, undo, alerts,
// window titles and the file-action copy.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class SharedPrimitivesTests: XCTestCase {

    private func group(_ name: String, raw: Bool = false) -> ImageGroup {
        let url = URL(fileURLWithPath: "/tmp/shrike-shared/\(name)")
        guard raw else { return ImageGroup(primary: url) }
        let rawURL = url.deletingPathExtension().appendingPathExtension("NEF")
        return ImageGroup(primary: url, companions: [.init(url: rawURL, kind: .raw)])
    }

    // MARK: - GroupList / DisplayedItem

    func testGroupListBumpsGenerationOnEveryMutation() {
        var list = GroupList([group("a.jpg"), group("b.jpg"), group("c.jpg")])
        let g0 = list.generation
        let removed = list.remove(primaries: [group("b.jpg").primary])
        XCTAssertEqual(removed.map(\.index), [1])
        XCTAssertEqual(list.groups.map(\.displayName), ["a.jpg", "c.jpg"])
        XCTAssertGreaterThan(list.generation, g0)
        let g1 = list.generation
        list.insert(removed)
        XCTAssertEqual(list.groups.map(\.displayName), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertGreaterThan(list.generation, g1)
        XCTAssertTrue(list.remove(primaries: [URL(fileURLWithPath: "/nope.jpg")]).isEmpty)
    }

    func testGroupListFindsCompanions() {
        let list = GroupList([group("a.jpg"), group("DSC_1.jpg", raw: true)])
        XCTAssertEqual(list.index(of: URL(fileURLWithPath: "/tmp/shrike-shared/DSC_1.NEF")), 1)
        XCTAssertNil(list[5])
    }

    func testDisplayedItemEqualityIncludesGeneration() {
        let a = DisplayedItem(group: group("a.jpg"), listIndex: 0, generation: 1)
        let b = DisplayedItem(group: group("a.jpg"), listIndex: 0, generation: 2)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Toast

    func testToastDurations() {
        XCTAssertEqual(ToastContent("★", kind: .glyph).duration, 1.2)
        XCTAssertEqual(ToastContent("Copied").duration, 2.5)
        XCTAssertEqual(ToastContent("Moved", actionTitle: "Undo").duration, 4.0)
        XCTAssertEqual(ToastContent("Couldn't …", kind: .error).announcementPriority, .high)
        XCTAssertEqual(ToastContent("Copied").announcementPriority, .medium)
    }

    func testToastPlacement() {
        XCTAssertEqual(ToastPlacement.viewer.topOffset(safeAreaTop: 0), 120)
        XCTAssertEqual(ToastPlacement.viewer.topOffset(safeAreaTop: 100), 148)
        XCTAssertEqual(ToastPlacement.browser.topOffset(safeAreaTop: 52), 120)
        XCTAssertEqual(ToastPlacement.browser.topOffset(safeAreaTop: 100), 148)
    }

    func testToastShowReplacesAnnouncesAndRunsAction() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let host = ToastHostView(placement: .viewer)
        host.install(in: container)
        var spoken: [(String, NSAccessibilityPriorityLevel)] = []
        host.announce = { spoken.append(($0, $1)) }
        var undone = 0
        host.show(ToastContent("First"))
        host.show(ToastContent("Moved “a.jpg” to the Trash.", actionTitle: "Undo")) { undone += 1 }
        XCTAssertEqual(host.content?.message, "Moved “a.jpg” to the Trash.")
        XCTAssertEqual(host.actionTitleForTesting, "Undo")
        XCTAssertEqual(spoken.map(\.0), ["First", "Moved “a.jpg” to the Trash."])
        XCTAssertTrue(host.isAccessibilityElement())
        host.pauseTimer()
        XCTAssertTrue(host.isPaused)
        host.resumeTimer()
        XCTAssertFalse(host.isPaused)
        host.performToastAction(nil)
        XCTAssertEqual(undone, 1)
        XCTAssertFalse(host.isShowing)
        XCTAssertFalse(host.isAccessibilityElement(), "hidden means gone")
    }

    /// Audit L17: the pointer rests on the toast, the user switches app: no mouseExited,
    /// so losing focus has to restart the clock.
    func testAToastPausedUnderThePointerResumesWhenTheAppLosesFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(container)
        let host = ToastHostView(placement: .viewer)
        host.install(in: container)
        host.show(ToastContent("Moved “a.jpg” to the Trash.", actionTitle: "Undo")) {}
        host.pauseTimer()
        XCTAssertTrue(host.isPaused)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(host.isPaused)
        host.pauseTimer()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(host.isPaused)
    }

    // MARK: - Alerts

    func testAlertButtonsAreAddedRightToLeft() {
        let alert = ShrikeAlert.make(
            message: "“a.jpg” can't be moved to the Trash.",
            buttons: [.cancel(), .init("Delete Immediately", role: .destructive)]
        )
        // NSAlert's first button is the rightmost: the last in visual order.
        XCTAssertEqual(alert.buttons.map(\.title), ["Delete Immediately", "Cancel"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "destructive is never the default")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(ShrikeAlert.index(of: .alertFirstButtonReturn, buttonCount: 2), 1)
        XCTAssertEqual(ShrikeAlert.index(of: .alertSecondButtonReturn, buttonCount: 2), 0)
        XCTAssertNil(ShrikeAlert.index(of: .cancel, buttonCount: 2))
    }

    // MARK: - Titles

    func testWindowTitles() {
        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 42, total: 180, pixelSize: nil), "43 of 180")
        XCTAssertEqual(
            WindowTitles.viewerSubtitle(index: 42, total: 180, pixelSize: CGSize(width: 6000, height: 4000)),
            "43 of 180 · 6000 × 4000"
        )
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 252, total: 252), "252 photos")
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 47, total: 252), "47 of 252 photos")
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 1, total: 1), "1 photo")
    }

    // MARK: - Copy

    func testTrashCopy() {
        XCTAssertEqual(FileActionCopy.movedToTrash([group("DSC_0042.jpg")]),
                       "Moved “DSC_0042.jpg” to the Trash.")
        XCTAssertEqual(FileActionCopy.movedToTrash([group("DSC_0042.jpg", raw: true)]),
                       "Moved “DSC_0042.jpg” and its RAW file to the Trash.")
        XCTAssertEqual(FileActionCopy.movedToTrash((0..<12).map { group("\($0).jpg") }),
                       "Moved 12 items to the Trash.")
        let readOnly = FileOpsError.readOnlyVolume(URL(fileURLWithPath: "/Volumes/SD"))
        XCTAssertEqual(FileActionCopy.trashFailed(group("x.jpg"), error: readOnly),
                       "Couldn't move “x.jpg” to the Trash — the volume is read-only.")
        XCTAssertEqual(FileActionCopy.putBack(original: group("a.jpg"), restored: group("a 2.jpg")),
                       "Put back as “a 2.jpg”.")
        XCTAssertEqual(ViewerWindow.edgeCopy(.next, current: "Day 1", target: "Day 2"),
                       "Last photo. Press → again to open “Day 2”.")
        XCTAssertEqual(ViewerWindow.edgeCopy(.previous, current: "Day 1", target: nil),
                       "First photo in “Day 1”.")
    }

    // MARK: - Viewer undo

    func testViewerKeepsItsOwnUndoStackAndDisplayedItem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) }
        for url in urls { try Data([0]).write(to: url) }
        let viewer = ViewerWindow(
            groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
            services: ShrikeServices.makeDefault()
        )
        defer { viewer.close() }
        XCTAssertEqual(viewer.undoManagerForTesting.levelsOfUndo, 50)
        XCTAssertTrue(viewer.undoManager === viewer.undoManagerForTesting)
        viewer.markDisplayedForTesting(1)
        XCTAssertEqual(viewer.displayedItem?.group.primary.lastPathComponent, "b.jpg")
        XCTAssertEqual(viewer.title, "b.jpg")
        XCTAssertEqual(viewer.representedURL?.lastPathComponent, "b.jpg")
        XCTAssertEqual(viewer.animationBehavior, .none, "U2: no window animation")
    }
}

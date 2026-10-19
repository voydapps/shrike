import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class EditPrimaryTitleSizingTests: XCTestCase {
    private func window(_ controller: EditToolbarController, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Primary title sizing fixture"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.toolbar = controller.toolbar
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func settle(_ window: NSWindow) async {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    private func assertComplete(_ controller: EditToolbarController, state: EditChromeState,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let button = controller.doneButton
        XCTAssertEqual(button.title, state.primaryTitle, file: file, line: line)
        let cell = try XCTUnwrap(button.cell, file: file, line: line)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let advance = button.attributedTitle.size().width
        XCTAssertGreaterThanOrEqual(titleRect.width + 0.5, advance,
            "The allocated native title region must fit the complete current text", file: file, line: line)
        XCTAssertLessThanOrEqual(titleRect.maxX, button.bounds.maxX + 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(titleRect.minX, button.bounds.minX - 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(titleRect.minY, button.bounds.minY - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(titleRect.maxY, button.bounds.maxY + 0.5, file: file, line: line)
        let visible = controller.toolbar.visibleItems?.map(\.itemIdentifier) ?? []
        XCTAssertTrue(visible.contains(EditToolbarController.ItemID.done), "Primary stays visible while lower-priority items may overflow", file: file, line: line)
        let secondary = controller.toolbar.items.filter { $0.itemIdentifier == EditToolbarController.ItemID.saveCopy }
        XCTAssertEqual(secondary.count, state.hasEdits && !state.requiresCopy ? 1 : 0, file: file, line: line)
        XCTAssertEqual(button.keyEquivalent, "\r", file: file, line: line)
        XCTAssertEqual(button.isEnabled, !state.isSaving, file: file, line: line)
    }

    func testAttachedPrimaryFitsCompleteTitlesAtWideAndMinimumWidths() async throws {
        for width: CGFloat in [2400, 648] {
            let controller = EditToolbarController()
            let window = window(controller, width: width)
            defer { window.close() }
            await settle(window)
            let states = [EditChromeState(), EditChromeState(hasEdits: true),
                EditChromeState(hasEdits: true, requiresCopy: true),
                EditChromeState(hasEdits: true, requiresCopy: true, isSaving: true), EditChromeState()]
            for _ in 0..<2 {
                var widths: [CGFloat] = []
                for state in states {
                    controller.apply(state)
                    await settle(window)
                    try assertComplete(controller, state: state)
                    widths.append(controller.doneButton.bounds.width)
                }
                XCTAssertGreaterThan(widths[1], widths[0], "Save Changes expands beyond Done")
                XCTAssertLessThan(widths[2], widths[1], "Save Copy releases unused title width")
                XCTAssertLessThan(widths[3], widths[2], "Saving uses its current title width")
                XCTAssertLessThan(widths[4], widths[3], "Returning to Done releases saved title width")
                XCTAssertEqual(widths[4], widths[0], accuracy: 0.5)
            }
        }
    }

    func testDirtyInitialAttachmentAndIndependentToolbarReattachmentFitFullTitles() async throws {
        let ordinary = EditToolbarController(), copyOnly = EditToolbarController()
        let dirty = EditChromeState(hasEdits: true), copy = EditChromeState(hasEdits: true, requiresCopy: true)
        ordinary.apply(dirty); copyOnly.apply(copy)
        let a = window(ordinary, width: 1200), b = window(copyOnly, width: 648)
        defer { a.close(); b.close() }
        await settle(a); await settle(b)
        try assertComplete(ordinary, state: dirty); try assertComplete(copyOnly, state: copy)
        for state in [EditChromeState(), copy, EditChromeState(hasEdits: true, isSaving: true), dirty] {
            a.toolbar = nil
            ordinary.apply(state)
            a.toolbar = ordinary.toolbar
            await settle(a)
            try assertComplete(ordinary, state: state)
            try assertComplete(copyOnly, state: copy)
        }
    }
}

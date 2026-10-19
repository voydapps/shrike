import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class EditToolbarParticipationTests: XCTestCase {
    private func makeWindow(_ controller: EditToolbarController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = controller.toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return window
    }

    private func assertParticipation(_ controller: EditToolbarController, state: EditChromeState,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let ids = controller.toolbar.items.map(\.itemIdentifier)
        let secondary = ids.filter { $0 == EditToolbarController.ItemID.saveCopy }
        let expected = state.hasEdits && !state.requiresCopy
        XCTAssertEqual(secondary.count, expected ? 1 : 0,
            "A hidden child must not leave a native toolbar wrapper or overflow entry", file: file, line: line)
        let primaryIndex = try XCTUnwrap(ids.firstIndex(of: EditToolbarController.ItemID.done), file: file, line: line)
        if expected {
            XCTAssertEqual(ids.firstIndex(of: EditToolbarController.ItemID.saveCopy), primaryIndex - 1,
                "Restore the secondary immediately before the primary", file: file, line: line)
        } else {
            XCTAssertEqual(ids[primaryIndex - 1], EditToolbarController.ItemID.reset,
                "Reset and primary must be adjacent without an empty secondary slot", file: file, line: line)
        }
        let primary = controller.toolbar.items[primaryIndex]
        XCTAssertEqual(primary.label, state.primaryTitle, file: file, line: line)
        XCTAssertEqual(primary.menuFormRepresentation?.title, state.primaryTitle, file: file, line: line)
        XCTAssertEqual(primary.menuFormRepresentation?.isEnabled, !state.isSaving, file: file, line: line)
        XCTAssertEqual(controller.doneButton.isEnabled, !state.isSaving, file: file, line: line)
        let secondaryForms = controller.toolbar.items.filter { $0.itemIdentifier == EditToolbarController.ItemID.saveCopy }
            .compactMap(\.menuFormRepresentation)
        XCTAssertEqual(secondaryForms.map(\.title), expected ? ["Save Copy…"] : [], file: file, line: line)
        for form in secondaryForms { XCTAssertEqual(form.isEnabled, !state.isSaving, file: file, line: line) }
    }

    func testInstalledSecondaryTracksCleanDirtyCopyOnlyAndRepeatedTransitions() throws {
        let controller = EditToolbarController()
        let window = makeWindow(controller)
        defer { window.close() }
        let states = [EditChromeState(), EditChromeState(hasEdits: true),
            EditChromeState(hasEdits: true, requiresCopy: true), EditChromeState(requiresCopy: true),
            EditChromeState(), EditChromeState(hasEdits: true),
            EditChromeState(hasEdits: true, isSaving: true), EditChromeState(hasEdits: true)]
        for _ in 0..<3 {
            for state in states {
                controller.apply(state); controller.apply(state)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try assertParticipation(controller, state: state)
            }
        }
    }

    func testDifferentEditWindowsKeepIndependentSecondaryMembership() throws {
        let ordinary = EditToolbarController(), copyOnly = EditToolbarController()
        let a = makeWindow(ordinary), b = makeWindow(copyOnly)
        defer { a.close(); b.close() }
        let copyState = EditChromeState(hasEdits: true, requiresCopy: true)
        copyOnly.apply(copyState)
        ordinary.apply(EditChromeState(hasEdits: true))
        XCTAssertNotEqual(ordinary.toolbar.identifier, copyOnly.toolbar.identifier,
            "Per-window save actions must not be synchronized by AppKit")
        try assertParticipation(ordinary, state: EditChromeState(hasEdits: true))
        try assertParticipation(copyOnly, state: copyState)
        copyOnly.apply(EditChromeState())
        try assertParticipation(ordinary, state: EditChromeState(hasEdits: true))
        try assertParticipation(copyOnly, state: EditChromeState())
    }

    func testDirtyBeforeFirstAttachAndNativeToolbarRestorationNeverDuplicateSecondary() throws {
        for initial in [EditChromeState(hasEdits: true), EditChromeState(hasEdits: true, requiresCopy: true)] {
            let controller = EditToolbarController()
            controller.apply(initial)
            let window = makeWindow(controller)
            defer { window.close() }
            try assertParticipation(controller, state: initial)
            for width: CGFloat in [648, 1000, 648] {
                window.setContentSize(NSSize(width: width, height: 600))
                for state in [EditChromeState(hasEdits: true), EditChromeState(hasEdits: true, requiresCopy: true), initial] {
                    window.toolbar = nil
                    controller.apply(state)
                    window.toolbar = controller.toolbar
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    try assertParticipation(controller, state: state)
                }
            }
        }
    }

    func testNarrowToolbarOverflowAndCapsuleRoundTripKeepOnlyIntendedSaveActions() throws {
        let controller = EditToolbarController()
        let window = makeWindow(controller)
        defer { window.close() }
        let capsule = EditCapsuleView()
        var actions: [EditChromeAction] = []
        controller.onAction = { actions.append($0) }
        let states = [EditChromeState(hasEdits: true, requiresCopy: true),
            EditChromeState(), EditChromeState(hasEdits: true)]
        for width: CGFloat in [648, 1000, 648] {
            window.setContentSize(NSSize(width: width, height: 600))
            for state in states {
                controller.apply(state)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try assertParticipation(controller, state: state)
                // The fullscreen stack has no native toolbar wrapper; preserve its existing predicate.
                window.toolbar = nil; capsule.apply(state)
                let copies = capsule.allSubviewsForTesting.compactMap { $0 as? NSButton }.filter { $0.title == "Save Copy…" }
                XCTAssertEqual(copies.count, state.requiresCopy && state.hasEdits ? 2 : 1)
                let visibleCopies = copies.filter { !$0.isHidden }
                XCTAssertEqual(visibleCopies.count, state.hasEdits ? 1 : 0)
                window.toolbar = controller.toolbar
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try assertParticipation(controller, state: state)
                controller.doneButton.performClick(nil)
                XCTAssertEqual(actions.last, .done, "The primary keeps its existing routing")
                if state.hasEdits && !state.requiresCopy {
                    let secondary = try XCTUnwrap(controller.toolbar.items.first { $0.itemIdentifier == EditToolbarController.ItemID.saveCopy }?.menuFormRepresentation)
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
                    XCTAssertEqual(actions.last, .saveCopy)
                }
            }
        }
    }
}

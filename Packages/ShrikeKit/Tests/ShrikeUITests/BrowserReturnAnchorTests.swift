import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
private final class ReturnButtonHost: ViewerToolbarHost {
    var enabled = true
    var performed: [ShrikeCommand] = []
    func canPerform(_ command: ShrikeCommand) -> Bool { enabled }
    func perform(_ command: ShrikeCommand) { performed.append(command) }
    func menuState(for command: ShrikeCommand) -> NSControl.StateValue { .off }
    var toolbarZoomLine: String { "Fit" }
    var toolbarShareURLs: [URL] { [] }
    var toolbarInspectorShown: Bool { false }
    var toolbarZoomPercent: Int? { 100 }
    func toolbarToggleIsOn(_ command: ShrikeCommand) -> Bool { false }
}

@MainActor
final class BrowserReturnAnchorTests: XCTestCase {
    private func fixture() -> (NSWindow, ViewerWindowToolbar, ReturnButtonHost) {
        let host = ReturnButtonHost()
        let bar = ViewerWindowToolbar(host: host)
        bar.toolbar.autosavesConfiguration = false
        bar.toolbar.isVisible = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.toolbar = bar.toolbar
        while !bar.toolbar.items.isEmpty { bar.toolbar.removeItem(at: 0) }
        for (index, id) in ViewerWindowToolbar.defaultItems.enumerated() {
            bar.toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        bar.validate()
        window.orderFront(nil)
        layout(window)
        return (window, bar, host)
    }

    private func layout(_ window: NSWindow) {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    func testOwnedMomentaryReturnButtonDispatchesOnceAndHonorsValidation() throws {
        let (window, bar, host) = fixture()
        defer { window.toolbar = nil; window.close() }
        let item = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.showInBrowser))
        let button = try XCTUnwrap(item.view as? NSButton)
        XCTAssertFalse(button is ToolbarToggleButton)
        XCTAssertEqual(button.bezelStyle, .toolbar)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.imageScaling, .scaleNone)
        XCTAssertTrue(button.target === bar)
        button.performClick(nil)
        XCTAssertEqual(host.performed, [.showInBrowser])
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        XCTAssertTrue(cell.showsStateBy.isEmpty, "Return must not render a latched stored state")
        XCTAssertFalse(button.isHighlighted, "Momentary press highlighting must end after the click")
        host.enabled = false
        bar.validate()
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(try XCTUnwrap(item.menuFormRepresentation).isEnabled)
        button.performClick(nil)
        XCTAssertEqual(host.performed, [.showInBrowser])
        host.enabled = true
        bar.validate()
        button.performClick(nil)
        XCTAssertEqual(host.performed, [.showInBrowser, .showInBrowser])
        let overflow = try XCTUnwrap(item.menuFormRepresentation)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(overflow.action), to: overflow.target, from: overflow))
        XCTAssertEqual(host.performed, [.showInBrowser, .showInBrowser, .showInBrowser])
    }

    func testReturnContextPaletteAndAnchorFollowReorderRemovalAndVisibility() throws {
        let (window, bar, host) = fixture()
        defer { window.toolbar = nil; window.close(); withExtendedLifetime(host) {} }
        let id = ViewerWindowToolbar.ID.showInBrowser
        bar.updateReturnTitle("Pictures")
        let item = try XCTUnwrap(bar.item(id))
        let button = try XCTUnwrap(item.view as? NSButton)
        XCTAssertTrue(bar.returnAnchor === button)
        XCTAssertEqual(button.accessibilityLabel(), "Back to Pictures")
        XCTAssertEqual(button.toolTip, item.toolTip)
        XCTAssertEqual(item.menuFormRepresentation?.title, "Back to Pictures")
        XCTAssertEqual(item.visibilityPriority, .high)
        let palette = try XCTUnwrap(bar.toolbar(bar.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false))
        XCTAssertFalse(palette === item)
        XCTAssertNotNil(palette.image)
        XCTAssertEqual(palette.paletteLabel, item.paletteLabel)
        XCTAssertEqual(palette.view?.accessibilityLabel(), button.accessibilityLabel())
        XCTAssertEqual(palette.view?.toolTip, item.toolTip)
        XCTAssertTrue(bar.returnAnchor === button, "A palette copy must never become the anchor")
        let oldIndex = try XCTUnwrap(bar.toolbar.items.firstIndex { $0 === item })
        bar.toolbar.removeItem(at: oldIndex)
        layout(window)
        XCTAssertNil(bar.returnAnchor)
        bar.toolbar.insertItem(withItemIdentifier: id, at: bar.toolbar.items.count)
        layout(window)
        XCTAssertTrue(bar.returnAnchor === button)
        XCTAssertEqual(bar.toolbar.items.last?.itemIdentifier, id)
        XCTAssertEqual(button.accessibilityLabel(), "Back to Pictures")
        bar.toolbar.isVisible = false
        layout(window)
        XCTAssertNil(bar.returnAnchor)
        bar.toolbar.isVisible = true
        layout(window)
        XCTAssertTrue(bar.returnAnchor === button)
        button.isHidden = true
        XCTAssertNil(bar.returnAnchor)
        button.isHidden = false
        window.orderOut(nil)
        XCTAssertNil(bar.returnAnchor)
        window.orderFront(nil)
        layout(window)
        XCTAssertTrue(bar.returnAnchor === button)
        bar.updateReturnTitle(nil)
        XCTAssertEqual(button.accessibilityLabel(), "Show in Browser")
        XCTAssertEqual(button.toolTip, item.toolTip)
    }

    func testOverflowedReturnItemHasNoTeachingAnchor() throws {
        let (window, bar, host) = fixture()
        defer { window.toolbar = nil; window.close(); withExtendedLifetime(host) {} }
        let id = ViewerWindowToolbar.ID.showInBrowser
        let index = try XCTUnwrap(bar.toolbar.items.firstIndex { $0.itemIdentifier == id })
        bar.toolbar.removeItem(at: index)
        bar.toolbar.insertItem(withItemIdentifier: id, at: bar.toolbar.items.count)
        window.minSize = .zero
        window.setContentSize(NSSize(width: 80, height: 400))
        layout(window)
        let visible = try XCTUnwrap(bar.toolbar.visibleItems)
        XCTAssertFalse(visible.contains { $0.itemIdentifier == id }, "The fixture must exercise actual native toolbar overflow")
        XCTAssertNil(bar.returnAnchor, "Never point at the detached cached button in overflow")
        window.setContentSize(NSSize(width: 1200, height: 400))
        layout(window)
        XCTAssertNotNil(bar.returnAnchor)
    }
}

//
//  WindowedViewerChromeTests.swift
//  ShrikeUITests
//
//  The headless parts of the windowed viewer chrome: toolbar, window setup
//  and subtitle; lazy inspector toggle; keys never show the titlebar;
//  an open menu holds it; a failed titlebar lookup turns auto-hide
//  off; no Option-Command-I.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class WindowedViewerChromeTests: XCTestCase {

    private var dir: URL!
    private var savedInspectorPref = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspectorPref = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspectorPref
    }

    private func makeViewer() throws -> ViewerWindow {
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: a)
        try Data([0xFF, 0xD8, 0xFF]).write(to: b)
        return ViewerWindow(groups: [ImageGroup(primary: a), ImageGroup(primary: b)],
                            startIndex: 0, services: .makeDefault())
    }

    // User test 5: with the titlebar auto-hidden there is no empty band; the
    // photo canvas runs to the top of the window and the window paints no
    // titlebar backdrop of its own.
    func testCanvasExtendsUnderAHiddenTitlebar() throws {
        let window = try makeViewer()
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        let root = window.contentRootForTesting
        root.layoutSubtreeIfNeeded()
        let hider = try XCTUnwrap(window.autoHider)
        XCTAssertTrue(hider.isActive)
        hider.hideForTesting()
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.titlebarAppearsTransparent, "no system titlebar backdrop while auto-hide is on")
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        let canvas = root.imageView
        XCTAssertEqual(canvas.frame.maxY, root.bounds.maxY, accuracy: 0.5, "the canvas reaches the top edge")
        XCTAssertEqual(window.backgroundColor, .black)
    }

    /// The Full Screen button: last item before the Inspector, the
    /// system symbol, the label and tooltip "Enter Full Screen" with the
    /// live shortcut, and it sends the existing full-screen command.
    func testTheFullScreenButtonIsTheLastItemBeforeTheInspector() throws {
        let window = try makeViewer()
        defer { window.close() }
        let bar = try XCTUnwrap(window.toolbarController)
        let ids = bar.toolbar.items.map(\.itemIdentifier)
        let at = try XCTUnwrap(ids.firstIndex(of: ViewerWindowToolbar.ID.fullScreen))
        XCTAssertEqual(ids[at + 1], .inspectorTrackingSeparator)
        XCTAssertEqual(ids[at + 2], ViewerWindowToolbar.ID.inspector)
        let item = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.fullScreen))
        let button = try XCTUnwrap(item.view as? ToolbarToggleButton)
        XCTAssertEqual(button.command, .toggleFullScreen)
        XCTAssertEqual(button.accessibilityLabel(), "Enter Full Screen")
        XCTAssertEqual(item.label, "Enter Full Screen")
        XCTAssertEqual(item.toolTip, ShortcutTable.tooltip(for: .toggleFullScreen, context: .viewer))
        XCTAssertTrue(item.toolTip?.hasPrefix("Enter Full Screen") ?? false, item.toolTip ?? "nil")
        XCTAssertTrue(item.toolTip?.contains("⌃⌘F") ?? false, "the live shortcut: \(item.toolTip ?? "nil")")
        XCTAssertEqual(button.toolTip, item.toolTip)
        XCTAssertFalse(ViewerWindowToolbar.optionalButtons.contains { $0.0 == ViewerWindowToolbar.ID.fullScreen },
                       "listed once in the Customize palette")
        let allowed = bar.toolbarAllowedItemIdentifiers(bar.toolbar)
        XCTAssertEqual(allowed.filter { $0 == ViewerWindowToolbar.ID.fullScreen }.count, 1)
    }

    // 14 default items in order; window setup; subtitle rules.
    func testToolbarWindowSetupAndSubtitle() throws {
        let window = try makeViewer()
        defer { window.close() }
        XCTAssertEqual(window.toolbar?.identifier, "shrike.viewer.toolbar.v3")
        XCTAssertEqual(ViewerWindowToolbar.defaultItems.count, 14)
        XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), ViewerWindowToolbar.defaultItems)
        // Auto-hide is on by default: no titlebar backdrop under a hidden titlebar (user test 5).
        XCTAssertEqual(window.titlebarAppearsTransparent, window.autoHider?.isActive == true)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertTrue(window.toolbar?.allowsUserCustomization ?? false)
        // AppKit adds the toolbar's height to the frame minimum.
        XCTAssertEqual(window.minSize.width, 480)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 320)
        XCTAssertTrue(window.contentViewController is ViewerSplitController)
        let bar = try XCTUnwrap(window.toolbarController)
        XCTAssertFalse(bar.item(ViewerWindowToolbar.ID.edit)?.toolTip?.isEmpty ?? true)
        XCTAssertFalse(bar.item(ViewerWindowToolbar.ID.trash)?.toolTip?.isEmpty ?? true)

        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 42, total: 180, pixelSize: CGSize(width: 6000, height: 4000)),
                       "43 of 180 · 6000 × 4000")
        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 0, total: 1, pixelSize: CGSize(width: 6000, height: 4000)),
                       "6000 × 4000")
        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 42, total: 180, pixelSize: nil), "43 of 180")
        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 0, total: 0, pixelSize: nil), "No images")
    }

    // Command-I opens the system inspector. Its view is built on
    // the first expand, and no header read happens before that.
    func testInspectorIsLazyAndToggles() throws {
        let window = try makeViewer()
        defer { window.close() }
        let split = try XCTUnwrap(window.splitController)
        XCTAssertFalse(split.isInspectorShown)
        XCTAssertNil(split.inspectorController.contentView, "no inspector view before the first expand")
        XCTAssertFalse(window.contentRootForTesting.inspectorPanel.headerReadsEnabled)
        XCTAssertEqual(split.inspectorItem.minimumThickness, 240)
        XCTAssertEqual(split.inspectorItem.maximumThickness, 360)
        XCTAssertEqual(window.inspectorMenuTitle(), "Show Inspector")

        window.dispatch(.toggleInspector)
        XCTAssertTrue(split.isInspectorShown)
        XCTAssertFalse(split.inspectorItem.isCollapsed)
        XCTAssertNotNil(split.inspectorController.contentView)
        XCTAssertTrue(window.contentRootForTesting.inspectorPanel.headerReadsEnabled)
        XCTAssertEqual(window.inspectorMenuTitle(), "Hide Inspector")
        XCTAssertTrue(Prefs.viewerInspectorVisibleWindowed)

        // Full screen collapses it and puts it back after.
        split.willEnterFullScreen()
        XCTAssertFalse(split.isInspectorShown)
        split.willExitFullScreen()
        XCTAssertTrue(split.isInspectorShown)

        window.dispatch(.toggleInspector)
        XCTAssertFalse(split.isInspectorShown)
        XCTAssertFalse(Prefs.viewerInspectorVisibleWindowed)
    }

    // The auto-hide rules.
    func testAutoHideRules() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let fakeContainer = NSView()
        let hider = TitlebarAutoHider(window: window, enabled: true, lookup: { _ in fakeContainer })
        defer { hider.stop() }
        XCTAssertTrue(hider.isActive)
        XCTAssertFalse(hider.lookupFailed)

        // Keys change nothing.
        hider.keyPressed()
        XCTAssertTrue(hider.isShown)

        // An open menu holds it.
        hider.setMenuOpen(true)
        XCTAssertTrue(hider.currentHolds().contains(.menuOpen))
        hider.hideIfAllowed()
        XCTAssertTrue(hider.isShown)
        hider.setMenuOpen(false)
        XCTAssertFalse(hider.currentHolds().contains(.menuOpen))

        // The pointer over the titlebar holds it too.
        hider.pointerMoved(inTitlebar: true)
        XCTAssertTrue(hider.currentHolds().contains(.pointerInTitlebar))

        // The pref off: never active, shows at once.
        hider.isEnabled = false
        XCTAssertFalse(hider.isActive)
        XCTAssertTrue(hider.isShown)

        // The lookup fails, so auto-hide is off and the toolbar stays.
        let failed = TitlebarAutoHider(window: window, enabled: true, lookup: { _ in nil })
        defer { failed.stop() }
        XCTAssertTrue(failed.lookupFailed)
        XCTAssertFalse(failed.isActive)
        failed.pointerMoved(inTitlebar: false)
        failed.hideIfAllowed()
        XCTAssertTrue(failed.isShown)
    }

    /// Customize Toolbar is a sheet. Opening it shows the
    /// hidden titlebar at once (the toolbar is the drop target) and holds
    /// it until the sheet ends; a pointer resting on the titlebar holds
    /// it too, even when the last event was the canvas's exit.
    func testSheetsAndAPointerOnTheTitlebarKeepItShown() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let fakeContainer = NSView()
        let hider = TitlebarAutoHider(window: window, enabled: true, lookup: { _ in fakeContainer })
        defer { hider.stop() }
        var pointer: NSPoint? = NSPoint(x: 200, y: 100) // on the canvas
        hider.pointerLocation = { pointer }
        XCTAssertFalse(hider.pointerIsOverTitlebar())

        // At rest the titlebar is hidden; the palette opens as a sheet.
        hider.hideForTesting()
        XCTAssertFalse(hider.isShown)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        for _ in 0..<50 where !hider.isShown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(hider.isShown, "the sheet shows the titlebar")
        XCTAssertFalse(fakeContainer.isHidden)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertTrue(hider.currentHolds().contains(.sheet))
        hider.pointerExited()
        hider.hideIfAllowed()
        XCTAssertTrue(hider.isShown, "held while the sheet is open")
        window.endSheet(sheet)
        for _ in 0..<50 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(hider.currentHolds().contains(.sheet))

        // The pointer rests on the titlebar strip: held, though the last
        // event (the canvas's exit) cleared the event flag.
        pointer = NSPoint(x: 200, y: window.frame.height - 6)
        XCTAssertGreaterThan(pointer!.y, window.contentLayoutRect.maxY)
        hider.pointerExited()
        XCTAssertTrue(hider.pointerIsOverTitlebar())
        XCTAssertTrue(hider.currentHolds().contains(.pointerInTitlebar))
        // Off the window (to the right of it): no hold.
        pointer = NSPoint(x: window.frame.width + 40, y: window.frame.height - 6)
        XCTAssertFalse(hider.pointerIsOverTitlebar())
        pointer = nil
        XCTAssertFalse(hider.currentHolds().contains(.pointerInTitlebar))
    }

    // Option-Command-I is gone from the Mac preset.
    // The one key table (ShortcutTable) has no ⌥⌘I anywhere.
    func testNoOptionCommandIBinding() {
        let optionCommandI = KeyEventSnapshot(key: "i", modifiers: [.command, .option])
        for context in [ShrikeUI.ShortcutContext.viewer, .browser, .editMode] {
            XCTAssertNil(ShortcutTable.command(for: optionCommandI, context: context, preset: .macNative),
                         "\(context)")
        }
    }
}

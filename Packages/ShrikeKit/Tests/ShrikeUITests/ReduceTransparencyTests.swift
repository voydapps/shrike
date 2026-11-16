//
//  ReduceTransparencyTests.swift
//  ShrikeUITests
//
//  Spec 28 §16 (H-4): Reduce Transparency table and the error look.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI
import ShrikeIO

@MainActor
final class ReduceTransparencyTests: XCTestCase {

    override func tearDown() async throws {
        ReduceTransparency.overrideForTesting = nil
        ShrikeTokens.increaseContrastOverride = nil
    }

    // MARK: Pure decisions

    func testDecisionTable() {
        XCTAssertFalse(ReduceTransparency.hudUsesOpaqueFill(callerOpaque: false, reduce: false))
        XCTAssertTrue(ReduceTransparency.hudUsesOpaqueFill(callerOpaque: true, reduce: false))
        XCTAssertTrue(ReduceTransparency.hudUsesOpaqueFill(callerOpaque: false, reduce: true))
        XCTAssertTrue(ReduceTransparency.hudUsesSeparatorBorder(increaseContrast: false, reduce: true))
        XCTAssertFalse(ReduceTransparency.hudUsesSeparatorBorder(increaseContrast: false, reduce: false))
        XCTAssertEqual(ReduceTransparency.previewBadgeAlpha(reduce: false), 0.85)
        XCTAssertEqual(ReduceTransparency.previewBadgeAlpha(reduce: true), 1)
        XCTAssertEqual(ReduceTransparency.titlebarScrimAlpha(reduce: false), 0.85)
        XCTAssertEqual(ReduceTransparency.titlebarScrimAlpha(reduce: true), 1)
        XCTAssertEqual(ReduceTransparency.cropDimAlpha(reduce: false), 0.5)
        XCTAssertEqual(ReduceTransparency.cropDimAlpha(reduce: true), 0.7)
        XCTAssertEqual(ReduceTransparency.cropFrameLines(reduce: false),
                       .init(whiteWidth: 1, blackOutsideWidth: nil))
        XCTAssertEqual(ReduceTransparency.cropFrameLines(reduce: true),
                       .init(whiteWidth: 2, blackOutsideWidth: 1))
    }

    func testOverrideBeatsTheSystem() {
        ReduceTransparency.overrideForTesting = true
        XCTAssertTrue(ReduceTransparency.isOn)
        ReduceTransparency.overrideForTesting = false
        XCTAssertFalse(ReduceTransparency.isOn)
    }

    func testAnnounceOnlyWhenTheMessageAppearsOrChanges() {
        XCTAssertTrue(ErrorLook.shouldAnnounce(old: nil, new: "a"))
        XCTAssertTrue(ErrorLook.shouldAnnounce(old: "a", new: "b"))
        XCTAssertFalse(ErrorLook.shouldAnnounce(old: "a", new: "a"))
        XCTAssertFalse(ErrorLook.shouldAnnounce(old: "a", new: nil))
        XCTAssertFalse(ErrorLook.shouldAnnounce(old: nil, new: ""))
    }

    // MARK: Surfaces

    private func revealedSurface(opaque: Bool) -> (HUDSurfaceView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let surface = HUDSurfaceView(frame: NSRect(x: 10, y: 10, width: 120, height: 40))
        surface.usesOpaqueFill = opaque
        surface.isHidden = true
        window.contentView?.addSubview(surface)
        surface.isHidden = false
        window.contentView?.layoutSubtreeIfNeeded()
        return (surface, window)
    }

    func testHUDFillFollowsTheSetting() throws {
        ReduceTransparency.overrideForTesting = false
        let (surface, window) = revealedSurface(opaque: false)
        defer { window.close() }
        XCTAssertEqual(surface.look, .solid)
        XCTAssertFalse(surface.drawsOpaqueFillForTesting, "translucent while the setting is off")
        ReduceTransparency.overrideForTesting = true
        surface.applyContrastBorder()
        XCTAssertTrue(surface.drawsOpaqueFillForTesting, "opaque under Reduce Transparency")
        XCTAssertEqual(surface.fillLayerForTesting?.borderWidth, 1)
        XCTAssertEqual(surface.fillLayerForTesting?.borderColor,
                       NSColor.separatorColor.resolvedCGColor(for: surface.effectiveAppearance))
        ReduceTransparency.overrideForTesting = false
        surface.applyContrastBorder()
        XCTAssertFalse(surface.drawsOpaqueFillForTesting, "back when the setting goes off")
    }

    func testCallerOpaqueStaysOpaque() {
        ReduceTransparency.overrideForTesting = false
        let (surface, window) = revealedSurface(opaque: true)
        defer { window.close() }
        XCTAssertTrue(surface.drawsOpaqueFillForTesting)
    }

    func testPreviewBadgeFill() {
        ReduceTransparency.overrideForTesting = false
        let badge = PreviewBadgeView()
        XCTAssertEqual(badge.fillAlphaForTesting, 0.85, accuracy: 0.01)
        ReduceTransparency.overrideForTesting = true
        badge.applyFill()
        XCTAssertEqual(badge.fillAlphaForTesting, 1, accuracy: 0.01)
    }

    func testScrimAlphaReadsTheSetting() {
        ReduceTransparency.overrideForTesting = false
        XCTAssertEqual(TitlebarScrimView.currentFillAlpha, TitlebarScrimView.fillAlpha)
        ReduceTransparency.overrideForTesting = true
        XCTAssertEqual(TitlebarScrimView.currentFillAlpha, 1)
    }

    // MARK: Error look

    func testErrorMessageViewShowsIconBorderAndHelp() {
        let field = NSTextField()
        let view = ErrorMessageView()
        view.normalHelp = "Normal help"
        XCTAssertTrue(view.isHidden)
        view.set("Names can't contain “/” or “:”.", for: field)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.label.textColor, .systemRed)
        XCTAssertEqual(view.label.stringValue, "Names can't contain “/” or “:”.")
        XCTAssertTrue(field.hasErrorBorder)
        XCTAssertEqual(field.layer?.borderWidth, 1.5)
        XCTAssertEqual(field.accessibilityHelp(), "Names can't contain “/” or “:”.")
        XCTAssertTrue(view.arrangedSubviews.first is NSImageView, "icon before the words")
        view.set(nil, for: field)
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(field.hasErrorBorder)
        XCTAssertEqual(field.accessibilityHelp(), "Normal help")
    }

    func testRenameSheetShowsTheErrorLook() throws {
        let group = ImageGroup(primary: URL(fileURLWithPath: "/tmp/a.jpg"), companions: [])
        let model = RenameSheetModel(group: group, validate: { $0.contains("/") ? .invalidCharacters : .valid })
        let sheet = RenameSheet(model: model)
        sheet.fieldForTesting.stringValue = "a/b"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(sheet.errorViewForTesting.isHidden)
        XCTAssertTrue(sheet.fieldForTesting.hasErrorBorder)
        XCTAssertFalse(sheet.errorViewForTesting.label.stringValue.contains("⚠"))
        sheet.fieldForTesting.stringValue = "ab"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(sheet.errorViewForTesting.isHidden)
    }

    func testGoToFolderSheetShowsTheErrorLook() async throws {
        let sheet = GoToFolderSheet(base: nil, initialPath: "")
        XCTAssertFalse(sheet.fieldForTesting.hasErrorBorder)
        sheet.errorViewForTesting.set(GoToFolder.noFolderMessage, for: sheet.fieldForTesting)
        XCTAssertTrue(sheet.fieldForTesting.hasErrorBorder)
        XCTAssertEqual(sheet.fieldForTesting.accessibilityHelp(), GoToFolder.noFolderMessage)
    }

    func testInlineNoticeErrorKindShowsTheIcon() {
        let notice = InlineNotice()
        notice.show("Fine")
        XCTAssertFalse(notice.showsErrorIcon)
        notice.show("3 files could not be read", kind: .error)
        XCTAssertTrue(notice.showsErrorIcon)
        notice.show("Fine again")
        XCTAssertFalse(notice.showsErrorIcon)
    }
}

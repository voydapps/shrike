import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ErrorOverlayTypographyTests: XCTestCase {
    private var savedLarge = false
    override func setUp() async throws { savedLarge = Prefs.largerChrome }
    override func tearDown() async throws { Prefs.largerChrome = savedLarge }
    private func assertFits(_ overlay: ErrorOverlayView, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 { overlay.needsLayout = true; overlay.layoutSubtreeIfNeeded() }
        let body = overlay.bodyForTesting
        let needed = body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.bounds.width, height: 10000)).height ?? 0
        XCTAssertGreaterThanOrEqual(body.bounds.height, ceil(needed), "All error text must fit the actual current font and width", file: file, line: line)
        XCTAssertEqual(body.stringValue, ErrorOverlayView.message, file: file, line: line)
        XCTAssertEqual(body.font?.pointSize, ChromeTypography.size(ErrorOverlayView.bodyFontSize), file: file, line: line)
        XCTAssertTrue(overlay.bounds.contains(overlay.cardFrameForTesting), file: file, line: line)
        XCTAssertEqual(overlay.cardFrameForTesting.width, ErrorOverlayView.cardWidth, file: file, line: line)
        for button in [overlay.nextButton, overlay.revealButton] {
            guard let parent = button.superview else { XCTFail("Native recovery button missing", file: file, line: line); continue }
            XCTAssertTrue(overlay.bounds.contains(parent.convert(button.frame, to: overlay)), file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.bounds.height, button.fittingSize.height, file: file, line: line)
            XCTAssertFalse(button.refusesFirstResponder, file: file, line: line)
        }
    }
    func testLiveStandardLargeStandardKeepsWholeErrorAndRecoveryControlsAtSupportedWidths() {
        Prefs.largerChrome = false
        for width: CGFloat in [480, 650, 800] {
            let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: width, height: 320))
            var actions = 0
            overlay.configureRecovery(title: "Choose Another Photo…", revealAvailable: true) { actions += 1 }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                overlay.appearance = NSAppearance(named: appearance)
                for large in [false, true, false] {
                    Prefs.largerChrome = large
                    NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                    assertFits(overlay)
                }
            }
            overlay.nextButton.performClick(nil); XCTAssertEqual(actions, 1)
        }
    }
    func testViewerErrorKeepsWholeCopyInWindowAndFullscreenWithoutChangingPhotoIdentity() {
        Prefs.largerChrome = false
        let content = ViewerContentView(services: .makeDefault())
        content.frame = NSRect(x: 0, y: 0, width: 650, height: 500)
        content.imageView.setImage(SaveFlowTests.image(), sourceID: "error-photo")
        content.configureDecodeRecovery(title: "Choose Another Photo…", revealAvailable: true, action: {})
        content.showDecodeError()
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            content.windowMode = mode
            for large in [false, true, false] {
                Prefs.largerChrome = large
                NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                content.layoutSubtreeIfNeeded(); assertFits(content.errorOverlayForTesting)
                XCTAssertEqual(content.imageView.sourceID, "error-photo")
                XCTAssertEqual(content.imageView.alphaValue, 0)
            }
        }
    }
    func testFirstLargeErrorHasEnoughSpaceBeforeAnyPreferenceChange() {
        Prefs.largerChrome = true
        let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: 650, height: 320))
        assertFits(overlay)
    }
}

//
//  CropAndPhotoAccessibilityTests.swift
//  ShrikeUITests
//
//  Spec 28 §15 (H-3): the properties VoiceOver reads on the photo and on the
//  crop frame, and the crop frame's keys (key events sent to the overlay).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class CropAndPhotoAccessibilityTests: XCTestCase {

    // MARK: Photo view texts

    func testValueText() {
        XCTAssertEqual(PhotoViewAccessibility.value(pixelScale: 1, isPreview: false), "Zoom 100 percent")
        XCTAssertEqual(PhotoViewAccessibility.value(pixelScale: 0.4, isPreview: true), "Preview. Zoom 40 percent")
        XCTAssertEqual(PhotoViewAccessibility.value(pixelScale: 0.2449, isPreview: false), "Zoom 24 percent")
        XCTAssertEqual(PhotoViewAccessibility.valueDelay, 0.25)
    }

    func testHelpIsOnlyWhatIsTrueOfTheKeys() {
        for preset in ShortcutPreset.allCases {
            let table = { (command: ShrikeCommand) in
                ShortcutTable.bindings(for: command, context: .viewer, preset: preset)
            }
            let arrows = table(.nextImage).contains(KeyBinding(SpecialKey.right))
                && table(.previousImage).contains(KeyBinding(SpecialKey.left))
            let plusMinus = table(.zoomIn).contains(KeyBinding("+")) && table(.zoomOut).contains(KeyBinding("-"))
            let help = PhotoViewAccessibility.help(preset: preset) ?? ""
            XCTAssertEqual(help.contains("arrow keys"), arrows, "\(preset)")
            XCTAssertEqual(help.contains("plus or minus"), plusMinus, "\(preset)")
        }
        // The Mac preset zooms with ⌘+ / ⌘−: no "plus or minus" line.
        XCTAssertEqual(PhotoViewAccessibility.help(preset: .macNative), "Use the arrow keys to change photos.")
    }

    func testActionNames() {
        XCTAssertEqual(PhotoViewAccessibility.actionNames,
                       ["Zoom In", "Zoom Out", "Zoom to Fit", "Previous Photo", "Next Photo"])
    }

    // MARK: Photo view on the real view

    func testPhotoViewRoleLabelValueAndActions() throws {
        let content = ViewerContentView(services: ShrikeServices.makeDefault())
        var commands: [ViewerAction] = []
        content.installPhotoAccessibility { commands.append($0) }
        content.setPhotoAccessibilityName("DSC_0042.jpg")
        content.refreshPhotoAccessibilityValue(post: false)
        let view = content.imageView
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .image)
        XCTAssertEqual(view.accessibilityLabel(), "DSC_0042.jpg")
        XCTAssertEqual(view.accessibilityValue() as? String, content.photoAccessibilityValueForTesting)
        XCTAssertTrue((view.accessibilityValue() as? String)?.hasPrefix("Zoom ") == true)
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), PhotoViewAccessibility.actionNames)
        for action in actions { XCTAssertEqual(action.handler?(), true) }
        XCTAssertEqual(commands, [.zoomIn, .zoomOut, .zoomBestFit, .prevImage, .nextImage])
        content.setPhotoAccessibilityPreview(true)
        content.refreshPhotoAccessibilityValue(post: false)
        XCTAssertTrue((view.accessibilityValue() as? String)?.hasPrefix("Preview. Zoom ") == true)
    }

    /// A-1: a real photo replacing a preview clears "Preview." (setImage
    /// hides the badge through the one path that also clears the flag).
    func testSetImageClearsThePreviewFlag() throws {
        let content = ViewerContentView(services: ShrikeServices.makeDefault())
        content.installPhotoAccessibility { _ in }
        content.showPreviewBadge()
        XCTAssertTrue(content.photoAccessibility.isPreview)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        content.setImage(try XCTUnwrap(ctx.makeImage()), index: 0, total: 1)
        XCTAssertFalse(content.photoAccessibility.isPreview)
        content.refreshPhotoAccessibilityValue(post: false)
        XCTAssertFalse((content.imageView.accessibilityValue() as? String)?.hasPrefix("Preview.") ?? true)
    }

    /// A-2: installing on every photo change costs no shortcut lookups after
    /// the first; the help line is computed once per preset.
    func testRepeatedInstallDoesNoShortcutLookups() {
        let content = ViewerContentView(services: ShrikeServices.makeDefault())
        content.installPhotoAccessibility { _ in }
        let help = content.imageView.accessibilityHelp()
        let before = PhotoViewAccessibility.helpComputationsForTesting
        for i in 0..<50 {
            content.installPhotoAccessibility { _ in }
            content.setPhotoAccessibilityName("p\(i).jpg")
        }
        XCTAssertEqual(PhotoViewAccessibility.helpComputationsForTesting, before)
        XCTAssertEqual(content.imageView.accessibilityHelp(), help)
        XCTAssertEqual(content.imageView.accessibilityLabel(), "p49.jpg")
        let other = ViewerContentView(services: ShrikeServices.makeDefault())
        other.installPhotoAccessibility { _ in }
        XCTAssertEqual(PhotoViewAccessibility.helpComputationsForTesting, before, "cached per preset")
    }

    func testValueIsRefreshedOnceAfterTheLastZoomChange() async throws {
        let content = ViewerContentView(services: ShrikeServices.makeDefault())
        content.installPhotoAccessibility { _ in }
        let before = content.photoAccessibility.valuePosts
        for _ in 0..<5 { content.schedulePhotoAccessibilityValue() }
        XCTAssertEqual(content.photoAccessibility.valuePosts, before, "nothing at once")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(content.photoAccessibility.valuePosts, before + 1, "one post for five changes")
    }

    // MARK: Crop frame

    private func overlay() -> CropOverlayView {
        let view = CropOverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view.imagePixelSize = CGSize(width: 3000, height: 2000)
        view.imageFrame = CGRect(x: 0, y: 0, width: 300, height: 200)   // 10 image pixels per point
        view.setRectFromImageSpace(CGRect(x: 120, y: 80, width: 1000, height: 800))
        return view
    }

    private func press(_ view: NSView, _ key: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        view.keyDown(with: event)
    }

    private func arrow(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }

    func testFrameRoleLabelValueHelp() throws {
        let view = overlay()
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.accessibilityLabel(), "Crop frame")
        XCTAssertEqual(view.accessibilityValue() as? String, "1000 by 800 pixels, left 120, top 80")
        XCTAssertEqual(view.accessibilityHelp(),
                       "Arrow keys move the frame. Option and arrow keys resize it. Shift makes the steps 10 pixels.")
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSView])
        XCTAssertEqual(children.count, 8)
        XCTAssertEqual(children.map { $0.accessibilityRole() }, Array(repeating: .handle, count: 8))
        XCTAssertEqual(children.compactMap { $0.accessibilityLabel() },
                       ["Top left corner", "Top edge", "Top right corner", "Right edge",
                        "Bottom right corner", "Bottom edge", "Bottom left corner", "Left edge"])
    }

    func testHandlesAreAdjustableByOnePixel() throws {
        let view = overlay()
        let right = try XCTUnwrap((view.accessibilityChildren() as? [NSView])?[3])
        XCTAssertTrue(right.accessibilityPerformIncrement())
        XCTAssertEqual(view.accessibilityValue() as? String, "1001 by 800 pixels, left 120, top 80")
        XCTAssertTrue(right.accessibilityPerformDecrement())
        XCTAssertTrue(right.accessibilityPerformDecrement())
        XCTAssertEqual(view.accessibilityValue() as? String, "999 by 800 pixels, left 120, top 80")
        let topLeft = try XCTUnwrap((view.accessibilityChildren() as? [NSView])?[0])
        XCTAssertTrue(topLeft.accessibilityPerformIncrement())
        XCTAssertEqual(view.accessibilityValue() as? String, "1000 by 801 pixels, left 119, top 79")
    }

    func testArrowKeysMoveInImagePixelsNotPoints() {
        let view = overlay()
        press(view, arrow(NSRightArrowFunctionKey))
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 121, y: 80, width: 1000, height: 800))
        press(view, arrow(NSDownArrowFunctionKey), .shift)
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 121, y: 90, width: 1000, height: 800))
        press(view, arrow(NSLeftArrowFunctionKey), .shift)
        XCTAssertEqual(view.integralPixelRect?.minX, 111)
    }

    func testOptionResizesFromBottomRightAndControlOptionFromTopLeft() {
        let view = overlay()
        press(view, arrow(NSRightArrowFunctionKey), .option)
        press(view, arrow(NSDownArrowFunctionKey), [.option, .shift])
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 120, y: 80, width: 1001, height: 810))
        press(view, arrow(NSRightArrowFunctionKey), [.option, .control])
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 119, y: 80, width: 1002, height: 810))
        press(view, arrow(NSUpArrowFunctionKey), [.option, .control, .shift])
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 119, y: 90, width: 1002, height: 800))
    }

    func testFrameNeverLeavesThePhotoAndAnnouncesTheEdge() {
        let view = overlay()
        view.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 1000, height: 800))
        var now: TimeInterval = 100
        view.uptime = { now }
        press(view, arrow(NSLeftArrowFunctionKey))
        XCTAssertEqual(view.integralPixelRect, CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(view.announcementsForTesting.last, "Edge of photo")
        now += 1
        press(view, arrow(NSRightArrowFunctionKey))
        XCTAssertEqual(view.announcementsForTesting.last, "1000 by 800 pixels, left 1, top 0")
    }

    func testAnnouncementsAreThrottled() {
        let view = overlay()
        var now: TimeInterval = 50
        view.uptime = { now }
        press(view, arrow(NSRightArrowFunctionKey))
        now += 0.1
        press(view, arrow(NSRightArrowFunctionKey))
        XCTAssertEqual(view.announcementsForTesting.count, 1)
        XCTAssertEqual(view.integralPixelRect?.minX, 122, "the frame still moved")
        now += 0.2
        press(view, arrow(NSRightArrowFunctionKey))
        XCTAssertEqual(view.announcementsForTesting.count, 2)
    }

    func testAspectLockIsKept() {
        let view = overlay()
        view.setRectFromImageSpace(CGRect(x: 100, y: 100, width: 1500, height: 1000))
        view.aspectRatio = 1.5
        press(view, arrow(NSRightArrowFunctionKey), [.option, .shift])
        let rect = view.integralPixelRect!
        XCTAssertEqual(rect.width, 1510)
        XCTAssertEqual(rect.height, 1007)   // 1510 / 1.5 = 1006.67
    }

    func testReturnIsDoneEscapeReturnsFocusAndOtherKeysPassOn() {
        let view = overlay()
        var done = 0, esc = 0
        view.onDone = { done += 1 }
        view.onEscape = { esc += 1 }
        press(view, "\r")
        press(view, "\u{1b}")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(esc, 1)
        let before = view.integralPixelRect
        press(view, "x")
        press(view, arrow(NSRightArrowFunctionKey), .command)
        XCTAssertEqual(view.integralPixelRect, before)
    }

    func testNoKeysWhileGeometryInputIsOff() {
        let view = overlay()
        view.acceptsGeometryInput = false
        let before = view.integralPixelRect
        press(view, arrow(NSRightArrowFunctionKey))
        XCTAssertEqual(view.integralPixelRect, before)
        // Esc is never dead: it still gives the keyboard back.
        var esc = 0
        view.onEscape = { esc += 1 }
        press(view, "\u{1b}")
        XCTAssertEqual(esc, 1)
    }
}

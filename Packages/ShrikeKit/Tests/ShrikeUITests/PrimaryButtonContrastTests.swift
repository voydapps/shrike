import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PrimaryButtonContrastTests: XCTestCase {
    private func attributes(_ button: NSButton, context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard #available(macOS 26, *) else {
            XCTAssertEqual(button.accentFillMechanism, "accent", file: file, line: line)
            return
        }
        let value = button.attributedTitle
        XCTAssertEqual(value.string, button.title, context, file: file, line: line)
        guard value.length > 0 else { return XCTFail("Primary label must exist", file: file, line: line) }
        let color = value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let font = value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(color, "\(context): keep explicit glass-label foreground", file: file, line: line)
        XCTAssertEqual(font?.pointSize, button.font?.pointSize, "\(context): current font size", file: file, line: line)
        XCTAssertEqual(font?.fontName, button.font?.fontName, "\(context): current font face", file: file, line: line)
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits, button.font?.fontDescriptor.symbolicTraits,
            "\(context): current font traits", file: file, line: line)
        for appearance in [Contrast.light, Contrast.dark] {
            if button.isEnabled, let color {
                XCTAssertEqual(Contrast.resolve(color, in: appearance),
                    Contrast.resolve(NSColor.accentLabelColor, in: appearance), context, file: file, line: line)
            }
        }
    }

    func testActualEditToolbarAndCapsuleTitleTransitionsPreservePrimaryAttributes() {
        let toolbar = EditToolbarController(), capsule = EditCapsuleView()
        let states = [EditChromeState(), EditChromeState(hasEdits: true),
            EditChromeState(hasEdits: true, requiresCopy: true),
            EditChromeState(hasEdits: true, requiresCopy: true, isSaving: true), EditChromeState()]
        for appearance in [Contrast.light, Contrast.dark] {
          toolbar.doneButton.appearance = appearance; capsule.doneButton.appearance = appearance
          for state in states {
            toolbar.apply(state); capsule.apply(state)
            for (name, button) in [("toolbar", toolbar.doneButton), ("capsule", capsule.doneButton)] {
                XCTAssertEqual(button.title, state.primaryTitle)
                XCTAssertEqual(button.keyEquivalent, "\r")
                XCTAssertEqual(button.isEnabled, !state.isSaving)
                XCTAssertFalse(button.refusesFirstResponder)
                attributes(button, context: name + " " + state.primaryTitle)
            }
          }
        }
    }

    func testActualRecoveryTitleChangesPreserveAttributesAndActions() {
        let overlay = ErrorOverlayView()
        for title in ["Next Photo", "Previous Photo", "Back to Browser"] {
            var invoked = false
            overlay.configureRecovery(title: title, revealAvailable: true) { invoked = true }
            XCTAssertEqual(overlay.nextButton.title, title)
            attributes(overlay.nextButton, context: "recovery " + title)
            overlay.nextButton.performClick(nil)
            XCTAssertTrue(invoked)
            overlay.setNextEnabled(false)
            XCTAssertFalse(overlay.nextButton.isEnabled)
            attributes(overlay.nextButton, context: "disabled recovery " + title)
        }
    }

    func testActualLiveRecoveryFontChangesKeepAttributedFontCurrent() {
        let saved = Prefs.largerChrome
        defer {
            Prefs.largerChrome = saved
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        }
        Prefs.largerChrome = false
        let overlay = ErrorOverlayView()
        var actions = 0
        overlay.configureRecovery(title: "Back to Browser", revealAvailable: true) { actions += 1 }
        for large in [false, true, false] {
            Prefs.largerChrome = large
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
            XCTAssertEqual(overlay.nextButton.font?.pointSize, NSFont.systemFontSize + (large ? 2 : 0))
            attributes(overlay.nextButton, context: "recovery live Large=\(large)")
            overlay.nextButton.performClick(nil)
        }
        XCTAssertEqual(actions, 3)
    }

    func testRecoveryTypographyCallbackDoesNotRetainItsViewOrButton() {
        weak var view: ErrorOverlayView?
        weak var button: NSButton?
        autoreleasepool {
            let overlay = ErrorOverlayView()
            view = overlay; button = overlay.nextButton
            overlay.configureRecovery(title: "Back to Browser", revealAvailable: true) {}
        }
        XCTAssertNil(view)
        XCTAssertNil(button)
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertNil(view)
    }

    func testViewerOwnedLivePreferencesKeepCurrentToolbarAndFullscreenCapsuleTypography() async throws {
        let savedLarge = Prefs.largerChrome, savedReview = Prefs.reviewControlsVisible
        defer {
            Prefs.largerChrome = savedLarge; Prefs.reviewControlsVisible = savedReview
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        }
        Prefs.largerChrome = false; Prefs.reviewControlsVisible = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-primary-font-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("photo.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer {
            viewer.contentRootForTesting.editModeController.finalizeExit(); viewer.close()
        }
        viewer.setContentSize(NSSize(width: 1200, height: 800))
        let deadline = Date().addingTimeInterval(4)
        while !viewer.canPerform(.editImage), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard viewer.canPerform(.editImage) else { return XCTFail("The real photo must be ready to edit") }
        viewer.enterEditMode(landOn: nil); await viewer.waitForEditLoad()
        let content = viewer.contentRootForTesting
        XCTAssertTrue(content.isEditModeActive)
        let nativeToolbarSize = content.editToolbarController.doneButton.font?.pointSize
        for mode in [content.windowMode, .fullscreen] {
            content.windowMode = mode
            for large in [false, true, false] {
                Prefs.largerChrome = large
                NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                attributes(content.editToolbarController.doneButton, context: "real Viewer windowed-native \(large)")
                attributes(content.editCapsule.doneButton, context: "real Viewer \(mode) capsule \(large)")
                XCTAssertEqual(content.editToolbarController.doneButton.font?.pointSize, nativeToolbarSize,
                    "Native windowed toolbar typography is not forced to the task scale")
                XCTAssertEqual(content.editCapsule.doneButton.keyEquivalent, "\r")
            }
        }
    }

    func testForegroundMaximizesContrastAndMeetsNormalTextTarget() {
        let sampledNativeBlue = NSColor(srgbRed: 0, green: 126.0 / 255, blue: 1, alpha: 1)
        let colors: [NSColor] = [.black, .white, .systemBlue, .systemPurple, .systemPink, .systemRed,
            .systemOrange, .systemGreen, .systemYellow, .systemGray, sampledNativeBlue,
            NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)]
        for appearance in [Contrast.light, Contrast.dark] {
            for color in colors {
                let background = Contrast.resolve(color, in: appearance)
                let foreground = NSColor.accentLabelColor(for: background)
                let ratio = Contrast.ratio(foreground, on: background, in: appearance)
                let best = max(Contrast.ratio(.black, on: background, in: appearance),
                               Contrast.ratio(.white, on: background, in: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(background) in \(appearance.name.rawValue)")
                XCTAssertEqual(ratio, best, accuracy: 0.0001, "Choose the stronger foreground, without changing the accent")
            }
        }
    }
}

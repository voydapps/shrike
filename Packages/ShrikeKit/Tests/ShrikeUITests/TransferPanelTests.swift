import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

/// Production component geometry and ownership, without a filesystem transfer.
/// Real FileOps streams, cancellation and Undo remain in TransferProgressTests.
@MainActor
final class TransferPanelTests: XCTestCase {
    private var window: NSWindow!
    private var container: NSView!
    private var containerWidth: NSLayoutConstraint!
    private var host: ToastHostView!
    private var previousContrast: Bool?
    private var previousFallback = false

    override func setUp() async throws {
        _ = NSApplication.shared
        previousContrast = ShrikeTokens.increaseContrastOverride
        previousFallback = HUDGlass.forceFallbackForTesting
        ShrikeTokens.increaseContrastOverride = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = outer
        // NSWindow may grow to fit a view's minimum layout width. Keep the
        // requested test host width independent of that window fitting pass.
        container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(container)
        containerWidth = container.widthAnchor.constraint(equalToConstant: 800)
        NSLayoutConstraint.activate([
            containerWidth,
            container.heightAnchor.constraint(equalToConstant: 500),
            container.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            container.topAnchor.constraint(equalTo: outer.topAnchor),
        ])
        host = ToastHostView(placement: .browser)
        host.announce = { _, _ in }
        host.install(in: container)
    }

    override func tearDown() async throws {
        host.dismiss(animated: false)
        window.close()
        host = nil
        window = nil
        ShrikeTokens.increaseContrastOverride = previousContrast
        HUDGlass.forceFallbackForTesting = previousFallback
    }

    private func progress(_ message: String = "Moving 1 item…", fraction: Double = 0,
                          busy: Bool = true) -> ToastContent {
        var content = ToastContent(message)
        content.progress = fraction
        content.progressIsIndeterminate = busy
        return content
    }

    private func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    /// Compare actual child bounds in the shared host coordinate system. A bar
    /// can satisfy a width constraint while still extending beyond a short pill.
    private func assertContained(file: StaticString = #filePath, line: UInt = #line) {
        let bar = host.progressBarForTesting
        let barRect = bar.convert(bar.bounds, to: host)
        let title = host.labelForTesting
        let titleRect = title.convert(title.bounds, to: host)
        XCTAssertTrue(host.bounds.contains(barRect), file: file, line: line)
        XCTAssertTrue(host.bounds.contains(titleRect), file: file, line: line)
        XCTAssertEqual(barRect.minX, 16, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(host.bounds.maxX - barRect.maxX, 16, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(barRect.minY, 16, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(barRect.height, 6, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(titleRect.minY - barRect.maxY, 7.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(host.bounds.height, 60, file: file, line: line)
        XCTAssertFalse(host.hasAmbiguousLayout, file: file, line: line)
    }

    func testCompactCardContainsTrackAndKeepsWidthAcrossLongCountUpdates() throws {
        let ticket = host.showProgress(progress())
        host.alphaValue = 1
        layout()
        XCTAssertEqual(host.bounds.width, 280, accuracy: 0.5)
        assertContained()
        let initialWidth = host.bounds.width
        let long = String(repeating: "📷旅行・very-long-name-", count: 30)
        _ = try XCTUnwrap(host.updateProgress(progress(long, fraction: 0.35, busy: false), matching: ticket))
        layout()
        XCTAssertEqual(host.bounds.width, initialWidth, accuracy: 0.5)
        XCTAssertEqual(host.labelForTesting.toolTip, long)
        XCTAssertEqual(host.accessibilityLabel(), long)
        XCTAssertEqual(host.progressBarForTesting.accessibilityLabel(), long)
        XCTAssertEqual(host.labelForTesting.lineBreakMode, .byTruncatingMiddle)
        assertContained()
    }

    func testProgressCardYieldsToNarrowHostWithoutClipping() {
        host.show(progress())
        host.alphaValue = 1
        containerWidth.constant = 220
        layout()
        XCTAssertEqual(container.bounds.width, 220, accuracy: 0.5,
                       "The fixture must actually provide the requested narrow host")
        XCTAssertEqual(host.bounds.width, 188, accuracy: 0.5)
        let inContainer = host.convert(host.bounds, to: container)
        XCTAssertEqual(inContainer.minX, 16, accuracy: 0.5)
        XCTAssertEqual(container.bounds.maxX - inContainer.maxX, 16, accuracy: 0.5)
        assertContained()
    }

    func testLargerTitleGrowsCardInsteadOfClipping() {
        host.show(progress())
        host.alphaValue = 1
        layout()
        let initialHeight = host.bounds.height
        // Exercise the real intrinsic layout without changing user preferences.
        host.labelForTesting.font = .systemFont(ofSize: 24, weight: .semibold)
        layout()
        XCTAssertGreaterThan(host.bounds.height, initialHeight)
        assertContained()
    }

    func testNativeBusyThenMeasuredProgressDoesNotRestartFadeOrAnnouncement() async throws {
        var announcements: [String] = []
        host.announce = { text, _ in announcements.append(text) }
        let initial = host.showProgress(progress())
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(host.progressBarForTesting.fraction)
        XCTAssertEqual(host.content?.progress, 0)
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
        let measured = try XCTUnwrap(host.updateProgress(progress("Moving 2 of 4…", fraction: 0.35, busy: false), matching: initial))
        XCTAssertNotNil(host.progressBarForTesting.fraction)
        XCTAssertEqual(host.progressBarForTesting.fraction ?? -1, 0.35, accuracy: 0.001)
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(announcements, ["Moving 1 item…"])
        _ = try XCTUnwrap(host.updateProgress(progress("Moving 4 of 4…", fraction: 1, busy: false), matching: measured))
        XCTAssertEqual(host.progressBarForTesting.fraction ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(announcements.count, 1)
        layout()
        assertContained()
        _ = host.showProgress(progress("Copying 1 item…"))
        XCTAssertEqual(announcements, ["Moving 1 item…", "Copying 1 item…"],
                       "A fresh progress owner announces its start even when replacing another operation")
        XCTAssertNil(host.updateProgress(progress(), matching: measured))
    }

    func testProgressStaysOpaqueSolidWhenFullscreenGlassIsRequested() throws {
        for fallback in [false, true] {
            HUDGlass.forceFallbackForTesting = fallback
            host.setGlassLook(true)
            host.show(progress())
            host.alphaValue = 1
            layout()
            XCTAssertEqual(host.look, .solid)
            XCTAssertEqual(host.cornerRadiusForDisplay, 16, accuracy: 0.001)
            let fill = try XCTUnwrap(host.fillLayerForTesting)
            XCTAssertEqual(fill.backgroundColor?.alpha ?? 0, 1, accuracy: 0.001)
            let color = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(fill.backgroundColor))?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, 28.0 / 255, accuracy: 0.001)
            XCTAssertEqual(color.greenComponent, 28.0 / 255, accuracy: 0.001)
            XCTAssertEqual(color.blueComponent, 30.0 / 255, accuracy: 0.001)
            XCTAssertEqual(fill.borderWidth, 0.5, accuracy: 0.001)
            assertContained()
        }
    }

    func testLiveContrastBorderAndSettledBrightTitleInLightAndDarkSurroundings() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            container.appearance = NSAppearance(named: appearance)
            host.show(progress())
            try await Task.sleep(for: .milliseconds(180))
            layout()
            XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
            let title = try XCTUnwrap(host.labelForTesting.textColor?.usingColorSpace(.sRGB))
            XCTAssertEqual(title.redComponent, 1, accuracy: 0.001)
            XCTAssertEqual(title.greenComponent, 1, accuracy: 0.001)
            XCTAssertEqual(title.blueComponent, 1, accuracy: 0.001)
            XCTAssertEqual(title.alphaComponent, 1, accuracy: 0.001)
            ShrikeTokens.increaseContrastOverride = true
            host.applyContrastBorder()
            let fill = try XCTUnwrap(host.fillLayerForTesting)
            XCTAssertEqual(fill.borderWidth, 1, accuracy: 0.001)
            XCTAssertEqual(fill.borderColor?.alpha ?? 0, 0.35, accuracy: 0.001)
            ShrikeTokens.increaseContrastOverride = false
            host.applyContrastBorder()
            XCTAssertEqual(fill.borderWidth, 0.5, accuracy: 0.001)
            XCTAssertEqual(fill.borderColor?.alpha ?? 0, 0.16, accuracy: 0.001)
        }
    }

    func testReturningToOrdinaryUndoRestoresPillAndInvalidatesOldTicket() {
        host.setGlassLook(true)
        let old = host.showProgress(progress())
        host.alphaValue = 1
        layout()
        var performed = 0
        host.show(.trashed("Moved photo to the Trash."), action: { performed += 1 })
        host.alphaValue = 1
        layout()
        XCTAssertEqual(host.bounds.height, ToastHostView.height, accuracy: 0.5)
        XCTAssertEqual(host.glassShape, .capsule)
        XCTAssertEqual(host.surfaceStyle, ToastHostView.pillStyle)
        XCTAssertFalse(host.usesOpaqueFill)
        XCTAssertTrue(host.progressBarForTesting.isHidden)
        if HUDGlass.isAvailable { XCTAssertEqual(host.look, .glass) }
        host.dismissProgress(matching: old)
        XCTAssertTrue(host.isShowing)
        XCTAssertNil(host.updateProgress(progress(), matching: old))
        XCTAssertEqual(host.actionButtonForTesting.frame.height, host.bounds.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(host.actionButtonForTesting.bounds.width, 44)
        host.actionButtonForTesting.performClick(nil)
        XCTAssertEqual(performed, 1)
        XCTAssertFalse(host.isAccessibilityElement())
    }

    func testSingleItemCopyUsesReadableCountWithoutChangingMultiItemText() {
        XCTAssertEqual(FileTransferCopy.progress(.move, completed: 0, total: 1), "Moving 1 item…")
        XCTAssertEqual(FileTransferCopy.progress(.copy, completed: 0, total: 1), "Copying 1 item…")
        XCTAssertEqual(FileTransferCopy.progress(.move, completed: 2, total: 12), "Moving 3 of 12…")
    }
}

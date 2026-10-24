import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class VisualBundleRegressionTests: XCTestCase {

    // These exercise the real cell/editor installed in a panel, including the
    // vertical geometry which a suffix-only maxX assertion cannot detect.
    func testResizePercentOverflowInitialStandardStaysOnOneNativeLine() throws {
        try percentOverflow(initialLarge: false, live: false)
    }

    func testResizePercentOverflowInitialLargeStaysOnOneNativeLine() throws {
        try percentOverflow(initialLarge: true, live: false)
    }

    func testResizePercentOverflowLiveScalePreservesNativeEditorAndSelection() throws {
        try percentOverflow(initialLarge: false, live: true)
    }

    func testResizePercentUncommittedDraftSurvivesLiveScaleWithoutSemanticCallbacks() throws {
        try percentOverflow(initialLarge: false, live: true, typed: true)
    }

    private func percentOverflow(initialLarge: Bool, live: Bool, typed: Bool = false) throws {
        XCTAssertTrue(ShrikeDataPaths.isRunningTests)
        let testRoot = ShrikeDataPaths.testRoot.standardizedFileURL.path + "/"
        for path in [ShrikeDataPaths.applicationSupport.path, ShrikeDataPaths.caches.path,
                     try XCTUnwrap(ShrikeDefaults.testSuiteName)] {
            XCTAssertTrue(URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(testRoot),
                          "App stores must remain inside this XCTest process's temporary root")
        }
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = initialLarge
        let host = EditParameterPanel()
        let observation = ChromeTextObservation(root: host)
        let panel = ResizePanel()
        panel.sourcePixelSize = CGSize(width: 1536, height: 1024)
        host.install(panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.close(); withExtendedLifetime(observation) {} }
        host.layoutSubtreeIfNeeded()
        let field = panel._percentField
        var semanticCallbacks = 0
        panel.onDraftChanged = { semanticCallbacks += 1 }
        panel.onSpecChanged = { _ in semanticCallbacks += 1 }
        panel.onApply = { _ in semanticCallbacks += 1 }
        let suffix = try XCTUnwrap(controls(panel).compactMap { $0 as? NSTextField }.first { $0.stringValue == "%" })
        for value in typed ? ["123456789.5"] : ["100", "100.0", "1234.5", "123456789.5"] {
            window.makeFirstResponder(nil)
            field.stringValue = typed ? "100.0" : value
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            if typed {
                editor.undoManager?.removeAllActions()
                editor.selectAll(nil)
                editor.insertText(value, replacementRange: editor.selectedRange())
                editor.breakUndoCoalescing()
                if editor.allowsUndo { XCTAssertTrue(editor.undoManager?.canUndo == true) }
                XCTAssertEqual(editor.string, value)
            }
            func recordGeometry(_ phase: String) {
                let scroll = editor.enclosingScrollView
                let clip = editor.superview as? NSClipView
                print("PERCENT_VIEWPORT phase=\(phase) large=\(Prefs.largerChrome) value=\(value) selection=\(editor.selectedRange()) editorFrame=\(editor.frame) editorBounds=\(editor.bounds) visible=\(editor.visibleRect) scrollFrame=\(String(describing: scroll?.frame)) clipFrame=\(String(describing: clip?.frame)) clipBounds=\(String(describing: clip?.bounds)) container=\(String(describing: editor.textContainer?.containerSize)) origin=\(editor.textContainerOrigin)")
            }
            let scales = live ? [false, true, false] : [initialLarge]
            for large in scales {
                editor.setSelectedRange(NSRange(location: 1, length: 2))
                let callbacksBefore = semanticCallbacks
                let undoManager = editor.undoManager
                let couldUndo = undoManager?.canUndo
                let couldRedo = undoManager?.canRedo
                recordGeometry("before-font")
                Prefs.largerChrome = large
                NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
                recordGeometry("after-font")
                host.layoutSubtreeIfNeeded()
                recordGeometry("after-layout")
                for _ in 0..<3 {
                    panel.needsLayout = true
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(editor.string, value)
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
                }
                XCTAssertEqual(semanticCallbacks, callbacksBefore, "Layout/scale must not dispatch draft, change or Apply callbacks")
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertTrue(editor.delegate === field)
                if editor.allowsUndo {
                    XCTAssertTrue(editor.undoManager === undoManager)
                    XCTAssertEqual(editor.undoManager?.canUndo, couldUndo)
                    XCTAssertEqual(editor.undoManager?.canRedo, couldRedo)
                }
                XCTAssertTrue(field.currentEditor() === editor)
                XCTAssertEqual(editor.string, value)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
                XCTAssertEqual(editor.font?.pointSize, large ? 14 : 12)
                editor.selectAll(nil)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: value.utf16.count))
                let manager = try XCTUnwrap(editor.layoutManager)
                let container = try XCTUnwrap(editor.textContainer)
                manager.ensureLayout(for: container)
                let first = manager.glyphIndexForCharacter(at: 0)
                let last = manager.glyphIndexForCharacter(at: value.utf16.count - 1)
                let firstLine = manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
                let lastLine = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                XCTAssertEqual(firstLine.minY, lastLine.minY, accuracy: 0.5,
                               "First and final numeric glyphs must share one native line")
                XCTAssertEqual(manager.location(forGlyphAt: first).y + firstLine.minY,
                               manager.location(forGlyphAt: last).y + lastLine.minY, accuracy: 0.5,
                               "First and final numeric glyph baselines must match")
                editor.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
                editor.scrollRangeToVisible(editor.selectedRange())
                manager.ensureLayout(for: container)
                let suffixRect = field.convert(suffix.bounds, from: suffix)
                let viewport = editor.convert(editor.visibleRect, to: field)
                XCTAssertLessThanOrEqual(viewport.maxX, field.bounds.maxX + 1,
                                         "The native editor viewport stays within its numeric field")
                var finalGlyph = manager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
                finalGlyph.origin.x += editor.textContainerOrigin.x
                finalGlyph.origin.y += editor.textContainerOrigin.y
                finalGlyph = editor.convert(finalGlyph, to: field)
                let screenCaret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let caret = field.convert(window.convertFromScreen(screenCaret), from: nil)
                // firstRect for an offscreen first character can return an
                // AppKit sentinel. The layout manager retains its real line.
                let firstLineInEditor = firstLine.offsetBy(dx: editor.textContainerOrigin.x,
                                                          dy: editor.textContainerOrigin.y)
                let firstLineInField = editor.convert(firstLineInEditor, to: field)
                XCTAssertEqual(caret.minY, firstLineInField.minY, accuracy: 0.5,
                               "End caret must stay on the first numeric baseline")
                for rect in [finalGlyph, caret] {
                    XCTAssertGreaterThanOrEqual(rect.minX, viewport.minX - 1, "End glyph/caret must be visible horizontally")
                    XCTAssertLessThanOrEqual(rect.maxX, viewport.maxX + 1, "Native scrolling must expose the numeric end")
                    XCTAssertGreaterThanOrEqual(rect.minY, viewport.minY - 1, "End glyph/caret must be visible vertically")
                    XCTAssertLessThanOrEqual(rect.maxY, viewport.maxY + 1, "End glyph/caret must not wrap below the viewport")
                    XCTAssertLessThanOrEqual(rect.maxX + 1, suffixRect.minX, "Numeric end must stay before the suffix")
                }
                if manager.extraLineFragmentTextContainer != nil {
                    XCTAssertEqual(manager.extraLineFragmentRect.minY, firstLine.minY, accuracy: 0.5,
                                   "Terminal insertion fragment must not create another line")
                }
                XCTAssertEqual(editor.string, value)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: value.utf16.count, length: 0))
            }
            if typed, editor.allowsUndo {
                editor.undoManager?.undo()
                XCTAssertEqual(editor.string, "100.0", "Live resizing must retain the actual text Undo history")
                editor.undoManager?.redo()
                XCTAssertEqual(editor.string, value, "Text Redo must restore the uncommitted draft")
            }
            window.makeFirstResponder(nil)
            XCTAssertEqual(field.stringValue, value, "Blur must preserve the literal numeric value")
        }
    }

    private func controls(_ view: NSView) -> [NSControl] {
        ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
    }

    private func commit(_ value: String, in field: NSTextField) {
        field.stringValue = value
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
    }

    func testResizePreviewUsesEffectiveOutputAndUpdatesWhenUpscalingPolicyChanges() throws {
        let panel = ResizePanel()
        panel.sourcePixelSize = CGSize(width: 1536, height: 1024)
        var applied = 0
        panel.onApply = { _ in applied += 1 }
        commit("1234.5", in: panel._percentField)
        let raw = try XCTUnwrap(panel.currentSpec())
        XCTAssertGreaterThan(raw.width, 1536)
        XCTAssertGreaterThan(raw.height, 1024)
        XCTAssertEqual(panel._percentField.stringValue, "1234.5")
        XCTAssertNil(panel.pendingSpec)
        XCTAssertFalse(panel._applyButton.isEnabled)
        XCTAssertEqual(panel._previewLabel.stringValue, "Same size as the current photo.")
        panel._applyButton.performClick(nil)
        XCTAssertEqual(applied, 0)

        panel._preventUpscaleCheckbox.performClick(nil)
        XCTAssertFalse(panel.preventUpscale)
        XCTAssertEqual(panel.currentSpec()?.width, raw.width, "Toggling policy preserves the typed request")
        XCTAssertEqual(panel._percentField.stringValue, "1234.5")
        XCTAssertEqual(panel._previewLabel.stringValue, "New size: \(raw.width) × \(raw.height) px")
        XCTAssertTrue(panel._applyButton.isEnabled)
        panel._preventUpscaleCheckbox.performClick(nil)
        XCTAssertTrue(panel.preventUpscale)
        XCTAssertNil(panel.pendingSpec)
        XCTAssertFalse(panel._applyButton.isEnabled)
        XCTAssertEqual(panel._previewLabel.stringValue, "Same size as the current photo.")

        commit("50", in: panel._percentField)
        XCTAssertEqual(panel.pendingSpec?.width, 768)
        XCTAssertEqual(panel.pendingSpec?.height, 512)
        XCTAssertEqual(panel._previewLabel.stringValue, "New size: 768 × 512 px")
        XCTAssertTrue(panel._applyButton.isEnabled)
        panel._applyButton.performClick(nil)
        XCTAssertEqual(applied, 1, "A genuine downsize dispatches Apply once")

        panel._maintainCheckbox.performClick(nil)
        commit("2000", in: panel._widthField)
        commit("256", in: panel._heightField)
        XCTAssertFalse(panel.maintainAspect)
        XCTAssertEqual(panel.currentSpec()?.width, 2000)
        XCTAssertEqual(panel.currentSpec()?.height, 256)
        XCTAssertNotNil(panel.pendingSpec, "The independent height still changes")
        XCTAssertTrue(panel._applyButton.isEnabled)
        XCTAssertEqual(panel._previewLabel.stringValue, "New size: 1536 × 256 px")
        panel._preventUpscaleCheckbox.performClick(nil)
        XCTAssertEqual(panel._previewLabel.stringValue, "New size: 2000 × 256 px")
        panel._preventUpscaleCheckbox.performClick(nil)
        XCTAssertEqual(panel._previewLabel.stringValue, "New size: 1536 × 256 px")
        XCTAssertEqual(panel._widthField.stringValue, "2000")
    }

    func testLateInstalledResizeTracksLargeAndStandardWithoutRebasingOrLosingEditor() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = false
        let host = EditParameterPanel()
        let observation = ChromeTextObservation(root: host) // The real missed ordering: observe an empty slot.
        let panel = ResizePanel()
        panel.sourcePixelSize = CGSize(width: 1536, height: 1024)
        host.install(panel)
        host.frame = NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        let tracked = controls(panel).compactMap { control -> (NSControl, CGFloat, String?)? in
            guard let font = control.font, font.pointSize <= 17 else { return nil }
            return (control, font.pointSize, font.familyName)
        }
        XCTAssertGreaterThan(tracked.count, 10, "Fields, unit, headings, labels and buttons must be covered")
        XCTAssertTrue(window.makeFirstResponder(panel._percentField))
        panel._percentField.selectText(nil)
        let editor = try XCTUnwrap(panel._percentField.currentEditor())
        XCTAssertEqual(editor.font?.pointSize, 12)
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        host.layoutSubtreeIfNeeded()
        for (control, size, family) in tracked {
            XCTAssertEqual(control.font?.pointSize, size + 2)
            XCTAssertEqual(control.font?.familyName, family)
        }
        XCTAssertTrue(panel._percentField.currentEditor() === editor)
        XCTAssertEqual(editor.font?.pointSize, 14)
        let suffix = try XCTUnwrap(controls(panel).compactMap { $0 as? NSTextField }.first { $0.stringValue == "%" })
        let suffixRect = panel._percentField.convert(suffix.bounds, from: suffix)
        let rect = try XCTUnwrap(panel._percentField.cell).drawingRect(forBounds: panel._percentField.bounds)
        XCTAssertLessThanOrEqual(rect.maxX + 3, suffixRect.minX)
        // Repeated registration must not turn a standard baseline into a large one.
        ChromeTypography.register(host)
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(panel._widthField.font?.pointSize, 14)
        window.makeFirstResponder(nil)
        host.install(CropPanel())
        host.install(panel)
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(panel._heightField.font?.pointSize, 14)
        Prefs.largerChrome = false
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        for (control, size, family) in tracked {
            XCTAssertEqual(control.font?.pointSize, size)
            XCTAssertEqual(control.font?.familyName, family)
        }
        withExtendedLifetime(observation) {}
    }

    func testInitiallyLargeNumericPanelsStartAtCurrentScaleAndRepeatedUpdatesDoNotGrowThem() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = true
        let host = EditParameterPanel()
        let panel = ResizePanel()
        host.install(panel)
        for field in [panel._widthField, panel._heightField, panel._percentField] {
            XCTAssertEqual(field.font?.pointSize, 14)
        }
        for _ in 0..<3 {
            ChromeTypography.register(host)
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        }
        XCTAssertEqual(panel._widthField.font?.pointSize, 14)
        XCTAssertEqual(CropPanel()._widthField.font?.pointSize, 14)
        Prefs.largerChrome = false
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(panel._widthField.font?.pointSize, 12)
        XCTAssertEqual(panel._heightField.font?.pointSize, 12)
        XCTAssertEqual(panel._percentField.font?.pointSize, 12)
    }

    func testNewLargeToolPanelsMatchTheFontsOfLiveEnlargedPanels() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        let factories: [() -> NSView] = [
            { CropPanel() }, { RotatePanel() }, { ResizePanel() },
            { ColorAdjustPanel() }, { LevelsPanel() }, { ChooseToolPanel() },
        ]
        for make in factories {
            Prefs.largerChrome = false
            let live = make()
            ChromeTypography.register(live)
            let standard = controls(live).compactMap { $0.font?.pointSize }
            Prefs.largerChrome = true
            ChromeTypography.update(live)
            let fresh = make()
            let liveFonts = controls(live).compactMap { $0.font }
            let freshFonts = controls(fresh).compactMap { $0.font }
            XCTAssertEqual(liveFonts.count, freshFonts.count)
            for (index, pair) in zip(liveFonts, freshFonts).enumerated() {
                XCTAssertEqual(pair.0.pointSize, standard[index] + 2)
                XCTAssertEqual(pair.1.pointSize, pair.0.pointSize, "Fresh Large and live Large must agree in \(type(of: live))")
                XCTAssertEqual(pair.1.familyName, pair.0.familyName)
            }
        }
    }

    func testLargePanelRemeasuresAcrossScrollingBoundaryAndKeepsBottomActionReachable() throws {
        let saved = Prefs.largerChrome
        let motion = ReduceMotion.overrideForTesting
        defer { Prefs.largerChrome = saved; ReduceMotion.overrideForTesting = motion }
        Prefs.largerChrome = false
        ReduceMotion.overrideForTesting = true
        let host = EditParameterPanel()
        let panel = ResizePanel()
        host.install(panel)
        let standardHeight = host.contentHeight
        XCTAssertGreaterThan(standardHeight, 100)
        host.bandHeightProvider = { standardHeight + 1 }
        host.install(panel)
        host.frame = NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: standardHeight + 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isScrolling)
        let initialWidthCount = panel.constraints.filter { $0.firstAttribute == .width && $0.secondItem == nil }.count
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.contentHeight, standardHeight + 1)
        XCTAssertTrue(host.isScrolling)
        let scroll = try XCTUnwrap(host.contentHost.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(document.frame.height, host.contentHeight, accuracy: 1)
        let reset = panel._resetButton.convert(panel._resetButton.bounds, to: document)
        document.scrollToVisible(reset)
        host.layoutSubtreeIfNeeded()
        let visibleDocument = scroll.contentView.documentVisibleRect.insetBy(dx: -1, dy: -1)
        XCTAssertTrue(visibleDocument.contains(reset), "The entire last action must be reachable and readable after scrolling")
        // A second Large update measures with its old explicit document height
        // temporarily disabled, and cannot add another width/height contract.
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.constraints.filter { $0.firstAttribute == .width && $0.secondItem == nil }.count, initialWidthCount)
        Prefs.largerChrome = false
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isScrolling)
        XCTAssertEqual(host.contentHeight, standardHeight, accuracy: 1)
        XCTAssertEqual(panel.constraints.filter { $0.firstAttribute == .height && $0.secondItem == nil }.count, 0,
                       "The old scroll document height must be removed")
    }

    func testRegisteredSeventeenPointFontReturnsFromNineteenToStandard() {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = false
        let label = NSTextField(labelWithString: "Task chrome")
        label.font = ChromeTypography.font(17, weight: .semibold)
        let observation = ChromeTextObservation(root: label)
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(label.font?.pointSize, 19)
        Prefs.largerChrome = false
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(label.font?.pointSize, 17)
        withExtendedLifetime(observation) {}
    }
}

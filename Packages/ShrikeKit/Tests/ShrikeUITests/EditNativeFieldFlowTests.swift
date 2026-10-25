import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeUI

/// Exercise the native field editor and toolbar actions, then inspect actual files.
@MainActor
final class EditNativeFieldFlowTests: XCTestCase {
    private var root: URL!
    private var savedPreset: ShortcutPreset!
    override func setUp() async throws {
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        root = TestScratch.directory.appendingPathComponent("shrike-native-edit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedPreset = Prefs.shortcutPreset; Prefs.shortcutPreset = .macNative
    }
    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
        EditExitModal.responderForTesting = nil
        Prefs.shortcutPreset = savedPreset
        try? FileManager.default.removeItem(at: root)
    }
    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }
    private func write(_ name: String, red: CGFloat = 1) throws -> URL {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 2400, height: 1600, red: red), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
    private func write16(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let values = (0..<(400 * 300)).map { UInt16($0 % 65536) }
        let data = values.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 400, height: 300, bitsPerComponent: 16, bitsPerPixel: 16,
            bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func viewer(_ urls: [URL], sources: [any ImageSource]? = nil) async throws -> ViewerWindow {
        var services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        services.backupStore = BackupStore(root: root.appendingPathComponent("backups"))
        let viewer = ViewerWindow(imageSources: sources ?? urls.map { FileImageSource(url: $0) }, startIndex: 0,
            services: services, groups: urls.map { ImageGroup(primary: $0) })
        viewer.alphaValue = 0; viewer.ignoresMouseEvents = true; viewer.animationBehavior = .none
        viewer.makeKeyAndOrderFront(nil); viewer.setContentSize(NSSize(width: 1200, height: 800))
        try await until("The first actual photo is ready") {
            viewer.navCoalescer.isIdle && viewer.displayedItem?.listIndex == 0
                && viewer.imageViewForTesting.image != nil && !viewer.imageViewForTesting.isCurrentImagePlaceholder
        }
        return viewer
    }
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in viewer: ViewerWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: viewer.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }
    private func enter(_ viewer: ViewerWindow, tool: EditTool) async throws {
        viewer.keyDown(with: try key("e", code: 14, modifiers: .command, in: viewer))
        await viewer.waitForEditLoad()
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
        try pick(tool, in: viewer)
        viewer.contentView?.layoutSubtreeIfNeeded()
    }
    private func pick(_ tool: EditTool, in viewer: ViewerWindow) throws {
        let picker = viewer.contentRootForTesting.editToolbarController.toolPicker
        let index = try XCTUnwrap(EditChromeTools.order.firstIndex(of: tool))
        let segment = try XCTUnwrap(picker.segmentViewsForTesting[index] as? EditToolPicker.SegmentView)
        XCTAssertTrue(segment.accessibilityPerformPress())
    }
    private func draft(_ text: String, into field: NSTextField, in viewer: ViewerWindow) throws {
        if let editor = field.currentEditor() as? NSTextView,
           viewer.firstResponder === editor, editor.window === viewer,
           editor.delegate === field, field.window === viewer {
            // Human replacement typing stays in the existing editor. Asking
            // for the NSTextField again would resign/commit that pending text.
        } else {
            XCTAssertTrue(viewer.makeFirstResponder(field))
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
    }
    private func type(_ text: String, into field: NSTextField, in viewer: ViewerWindow) async throws {
        try draft(text, into: field, in: viewer)
        viewer.sendEvent(try key("\r", code: 36, in: viewer))
        try await until("Return commits the field and releases its editor") { field.currentEditor() == nil }
    }
    private func blurFixture(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 1536, height: 1024), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func blurDraft(_ text: String, into field: NSTextField, in viewer: ViewerWindow) throws {
        viewer.contentView?.layoutSubtreeIfNeeded()
        viewer.contentRootForTesting.editModeController._installedToolForTesting?.layoutSubtreeIfNeeded()
        viewer.recalculateKeyViewLoop()
        _ = try XCTUnwrap(field.window === viewer ? field : nil,
                          "Numeric input must belong to the exact attached test window")
        if let editor = field.currentEditor() as? NSTextView,
           viewer.firstResponder === editor, editor.window === viewer, editor.delegate === field {
            // Continue typing in this field's existing owned editor.
        } else {
            _ = try XCTUnwrap(viewer.makeFirstResponder(field) ? field : nil,
                              "The requested numeric field must accept its editor")
        }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        _ = try XCTUnwrap(editor.window === viewer && editor.delegate === field
                          && viewer.firstResponder === editor ? editor : nil,
                          "Numeric typing requires the exact window/editor/delegate/first-responder owner")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Command-level AppKit end-edit/traversal coverage in the owned editor;
    /// real keyboard bindings and physical native focus are verified separately.
    private func tab(in viewer: ViewerWindow, backwards: Bool = false) throws {
        viewer.contentView?.layoutSubtreeIfNeeded()
        viewer.contentRootForTesting.editModeController._installedToolForTesting?.layoutSubtreeIfNeeded()
        viewer.recalculateKeyViewLoop()
        let editor = try XCTUnwrap(viewer.firstResponder as? NSTextView,
                                   "Tab requires the current owned field editor")
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        _ = try XCTUnwrap(editor.window === viewer && field.window === viewer
                          && field.currentEditor() === editor && viewer.firstResponder === editor ? editor : nil,
                          "Tab requires the exact attached numeric field/editor/window/delegate owner")
        let panel = try XCTUnwrap(viewer.contentRootForTesting.editModeController._installedToolForTesting)
        let numericFields: [NSTextField]
        if let resize = panel as? ResizePanel {
            numericFields = [resize._widthField, resize._heightField, resize._percentField]
        } else {
            let crop = try XCTUnwrap(panel as? CropPanel)
            numericFields = [crop._widthField, crop._heightField]
        }
        _ = try XCTUnwrap(numericFields.contains { $0 === field } ? field : nil,
                          "Tab input must belong to an expected current Crop/Resize numeric field")
        editor.doCommand(by: backwards ? #selector(NSResponder.insertBacktab(_:))
                                       : #selector(NSResponder.insertTab(_:)))
    }

    /// A real public window mouse-event route, including AppKit's mouse-up
    /// tracking. No field setters, target actions or delegate calls cause blur.
    private func clickField(_ field: NSTextField, in viewer: ViewerWindow) throws {
        viewer.contentView?.layoutSubtreeIfNeeded()
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: viewer.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let ignored = viewer.ignoresMouseEvents
        viewer.ignoresMouseEvents = false
        defer { viewer.ignoresMouseEvents = ignored }
        viewer.postEvent(try event(.leftMouseUp), atStart: true)
        viewer.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            XCTAssertEqual(up.windowNumber, viewer.windowNumber)
            viewer.sendEvent(up)
        }
        // A dequeued mouse-up must not masquerade as the next test's drag.
        let neutral = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: viewer.windowNumber, context: nil,
            subtype: 0, data1: 0, data2: 0))
        viewer.postEvent(neutral, atStart: true)
        _ = NSApp.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
    }

    private func panelStrings(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(panelStrings)
    }

    /// Traverse the dynamically installed production hierarchy without fixing
    /// its layout/key loop in the test. Physical key bindings are separate QA.
    private func installedTab(from field: NSTextField, in window: NSWindow, backwards: Bool = false) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        _ = try XCTUnwrap(field.window === window && editor.window === window
                          && editor.delegate === field && window.firstResponder === editor ? editor : nil,
                          "Traversal must start in the exact attached production field editor")
        editor.doCommand(by: backwards ? #selector(NSResponder.insertBacktab(_:))
                                       : #selector(NSResponder.insertTab(_:)))
    }

    private func assertSaveChangesChrome(_ viewer: ViewerWindow) throws {
        let chrome = viewer.contentRootForTesting.editToolbarController
        XCTAssertEqual(chrome.doneButton.title, "Save Changes")
        let item = try XCTUnwrap(viewer.toolbar?.items.first { $0.view === chrome.doneButton })
        XCTAssertEqual(item.label, "Save Changes")
        XCTAssertEqual(item.menuFormRepresentation?.title, "Save Changes")
    }
    private func dimensions(_ url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    func testResizeTabShiftTabAndClickAwayResolveLinkedDraftOnceBeforeApply() async throws {
        let url = try blurFixture("blur-linked.png"), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        viewer.recalculateKeyViewLoop()
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        let previous = panel.onSpecChanged
        var resolutions = 0
        panel.onSpecChanged = { spec in resolutions += 1; previous?(spec) }
        try blurDraft("768", into: panel._widthField, in: viewer)
        try tab(in: viewer)
        try await until("Tab moves from Width to Height") { panel._heightField.currentEditor() != nil }
        XCTAssertEqual(panel._widthField.integerValue, 768); XCTAssertEqual(panel._heightField.integerValue, 512)
        XCTAssertEqual(panel._percentField.doubleValue, 50, accuracy: 0.001)
        XCTAssertTrue(panelStrings(panel).contains("New size: 768 × 512 px"))
        XCTAssertTrue(panel._applyButton.isEnabled); XCTAssertEqual(resolutions, 1)
        try blurDraft("256", into: panel._heightField, in: viewer)
        try tab(in: viewer, backwards: true)
        try await until("Shift-Tab returns from Height to Width") { panel._widthField.currentEditor() != nil }
        XCTAssertEqual(panel._widthField.integerValue, 384); XCTAssertEqual(panel._heightField.integerValue, 256)
        XCTAssertEqual(panel._percentField.doubleValue, 25, accuracy: 0.001)
        XCTAssertEqual(resolutions, 2)
        try blurDraft("37.5", into: panel._percentField, in: viewer)
        resolutions = 0 // Isolate Percent's end-edit from leaving the prior Width editor.
        try clickField(panel._widthField, in: viewer)
        try await until("Click-away enters Width after committing Percent") { panel._widthField.currentEditor() != nil }
        XCTAssertEqual(panel._widthField.integerValue, 576); XCTAssertEqual(panel._heightField.integerValue, 384)
        XCTAssertEqual(panel._percentField.doubleValue, 37.5, accuracy: 0.001)
        XCTAssertEqual(resolutions, 1)
        let session = try XCTUnwrap(c.recipe), before = await session.snapshot()
        XCTAssertTrue(before.isEmpty); XCTAssertFalse(c.chromeState.canUndo)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 1536, height: 1024))
        XCTAssertEqual(try Data(contentsOf: url), original)
        panel._applyButton.performClick(nil); await c.settleForTesting()
        let accepted = await session.snapshot()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 576, height: 384))
        XCTAssertNil(panel.pendingSpec)
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 1536, height: 1024))
        c.performRedo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 576, height: 384))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testResizeUnlinkedBlurKeepsIndependentDimensions() async throws {
        let url = try blurFixture("blur-unlinked.png"), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel._maintainCheckbox.performClick(nil)
        XCTAssertFalse(panel.maintainAspect)
        try blurDraft("768", into: panel._widthField, in: viewer); try tab(in: viewer)
        try await until("Unlinked Width commits on Tab") { panel._widthField.currentEditor() == nil }
        XCTAssertEqual(panel._widthField.integerValue, 768); XCTAssertEqual(panel._heightField.integerValue, 1024)
        try blurDraft("256", into: panel._heightField, in: viewer); try tab(in: viewer, backwards: true)
        try await until("Unlinked Height commits on Shift-Tab") { panel._heightField.currentEditor() == nil }
        XCTAssertEqual(panel._widthField.integerValue, 768); XCTAssertEqual(panel._heightField.integerValue, 256)
        XCTAssertEqual(panel.pendingSpec?.width, 768); XCTAssertEqual(panel.pendingSpec?.height, 256)
        XCTAssertTrue(panel._applyButton.isEnabled)
        let session = try XCTUnwrap(c.recipe), operations = await session.snapshot()
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testResizeInvalidEmptyIdentityAndNoUpscaleBlurStayUnapplied() async throws {
        for text in ["invalid", "", "1536", "2000"] {
            let url = try blurFixture("blur-invalid-\(UUID()).png"), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            try await enter(viewer, tool: .resize)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            try blurDraft(text, into: panel._widthField, in: viewer)
            try tab(in: viewer)
            try await until("Invalid/identity Width still yields focus") { panel._widthField.currentEditor() == nil }
            if text == "2000" {
                // Keep the raw typed request, but effective identity has no Apply.
                XCTAssertNil(panel.pendingSpec)
                XCTAssertFalse(panel._applyButton.isEnabled)
                panel._applyButton.performClick(nil)
                await c.settleForTesting()
            } else {
                XCTAssertNil(panel.pendingSpec)
                XCTAssertFalse(panel._applyButton.isEnabled)
            }
            let session = try XCTUnwrap(c.recipe), operations = await session.snapshot()
            let undoDepth = await session.undoDepth, redoDepth = await session.redoDepth
            XCTAssertTrue(operations.isEmpty)
            XCTAssertEqual(undoDepth, 0); XCTAssertEqual(redoDepth, 0)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 1536, height: 1024))
            XCTAssertFalse(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.canRedo)
            XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.hasPendingToolEdits)
            XCTAssertFalse(c.hasPendingEdits)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testCropNumericTabAndClickAwayUpdateFreeAndLockedOverlayWithoutApplying() async throws {
        for locked in [false, true] {
            let url = try blurFixture("blur-crop-\(locked).png"), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            try await enter(viewer, tool: .crop)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
            if locked {
                // Configure the existing aspect control; only native numeric
                // editing and focus movement below cause the geometry draft.
                panel._aspectPopup.selectItem(at: CropPanel.Aspect.original.rawValue)
                _ = panel._aspectPopup.sendAction(panel._aspectPopup.action, to: panel._aspectPopup.target)
            }
            let previous = panel.onDimensionsEdited
            var resolutions = 0
            panel.onDimensionsEdited = { w, h, side in resolutions += 1; previous?(w, h, side) }
            try blurDraft("768", into: panel._widthField, in: viewer); try tab(in: viewer)
            try await until("Crop Width commits on Tab") { panel._widthField.currentEditor() == nil }
            let widthCrop = try XCTUnwrap(c.pendingCropRect())
            XCTAssertEqual(widthCrop.width, 0.5, accuracy: 0.0001)
            XCTAssertEqual(widthCrop.height, locked ? 0.5 : 1, accuracy: 0.0001)
            XCTAssertEqual(panel._widthField.integerValue, 768)
            XCTAssertEqual(panel._heightField.integerValue, locked ? 512 : 1024)
            XCTAssertEqual(resolutions, 1)
            try blurDraft("256", into: panel._heightField, in: viewer)
            try clickField(panel._widthField, in: viewer)
            try await until("Click-away commits Crop Height") { panel._heightField.currentEditor() == nil }
            let heightCrop = try XCTUnwrap(c.pendingCropRect())
            XCTAssertEqual(heightCrop.width, locked ? 0.25 : 0.5, accuracy: 0.0001)
            XCTAssertEqual(heightCrop.height, 0.25, accuracy: 0.0001)
            XCTAssertEqual(resolutions, 2)
            let draftSession = try XCTUnwrap(c.recipe), operations = await draftSession.snapshot()
            XCTAssertTrue(operations.isEmpty)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 1536, height: 1024))
            panel._applyButton.performClick(nil); await c.settleForTesting()
            let appliedSession = try XCTUnwrap(c.recipe), accepted = await appliedSession.snapshot()
            XCTAssertEqual(accepted.count, 1)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: locked ? 384 : 768, height: 256))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testBlurredResizeDraftToolChoicesPreserveApplyAndDoNotDuplicateHistory() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
            let url = try blurFixture("blur-tool-\(choice).png"), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            try await enter(viewer, tool: .resize)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            try blurDraft("768", into: panel._widthField, in: viewer); try tab(in: viewer)
            try await until("The first blurred resize is actionable") { panel._applyButton.isEnabled }
            panel._applyButton.performClick(nil); await c.settleForTesting()
            let session = try XCTUnwrap(c.recipe), accepted = await session.checkpoint()
            try blurDraft("384", into: panel._widthField, in: viewer); try tab(in: viewer)
            try await until("The next blurred resize is a draft") { panel.pendingSpec?.width == 384 }
            let previous = panel.onSpecChanged
            var flushed = 0, asks = 0
            panel.onSpecChanged = { spec in flushed += 1; previous?(spec) }
            EditToolTransitionModal.responderForTesting = { _ in asks += 1; return choice }
            try pick(.color, in: viewer); await c.settleForTesting()
            XCTAssertEqual(asks, 1)
            XCTAssertEqual(flushed, 1, "The focused Height flush uses its end-edit action exactly once")
            if choice == .keep {
                let operations = await session.snapshot(); XCTAssertEqual(operations.count, 2)
                XCTAssertEqual(c.currentPixelSize, CGSize(width: 384, height: 256))
                let prepared = await c.prepareForSave(); XCTAssertTrue(prepared)
                let after = await session.snapshot(); XCTAssertEqual(after, operations)
            } else {
                let retained = await session.checkpoint(); XCTAssertEqual(retained, accepted)
                XCTAssertEqual(c.currentPixelSize, CGSize(width: 768, height: 512))
                if choice == .cancel {
                    XCTAssertEqual(c.currentTool, .resize)
                    XCTAssertEqual(panel.pendingSpec?.width, 384); XCTAssertEqual(panel.pendingSpec?.height, 256)
                    XCTAssertNotNil(panel._heightField.currentEditor())
                } else { XCTAssertEqual(c.currentTool, .color); XCTAssertNil(c.pendingCropRect()) }
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testNumericReturnStillCommitsOnlyOnceBeforeASeparateDefaultSave() async throws {
        for tool in [EditTool.crop, .resize] {
            let url = try blurFixture("blur-return-\(tool).png"), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            try await enter(viewer, tool: tool)
            let c = viewer.contentRootForTesting.editModeController
            let field: NSTextField
            var resolved = 0
            if let panel = c._installedToolForTesting as? ResizePanel {
                field = panel._widthField
                let previous = panel.onSpecChanged
                panel.onSpecChanged = { spec in resolved += 1; previous?(spec) }
            } else {
                let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
                field = panel._widthField
                let previous = panel.onDimensionsEdited
                panel.onDimensionsEdited = { w, h, side in resolved += 1; previous?(w, h, side) }
            }
            var saves = 0
            let previousSave = c.onSaveRequested
            c.onSaveRequested = { saves += 1; previousSave?() }
            try blurDraft("768", into: field, in: viewer)
            viewer.sendEvent(try key("\r", code: 36, in: viewer))
            try await until("The first Return commits and relinquishes the field") { field.currentEditor() == nil }
            await c.settleForTesting()
            XCTAssertEqual(resolved, 1); XCTAssertEqual(saves, 0)
            XCTAssertTrue(c.isActive)
            let session = try XCTUnwrap(c.recipe), operations = await session.snapshot()
            XCTAssertTrue(operations.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), original)
            viewer.sendEvent(try key("\r", code: 36, in: viewer))
            try await until("Only a separate Return takes the default save route") { !c.isActive }
            XCTAssertEqual(saves, 1)
            XCTAssertEqual(try dimensions(url), CGSize(width: 768, height: tool == .resize ? 512 : 1024))
            let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).backupURL), original)
        }
    }

    func testProductionToolInstallRefreshesPrimedViewerLoopWithoutHelperRecalculation() async throws {
        for tool in [EditTool.crop, .resize] {
            let url = try blurFixture("dynamic-install-\(tool).png"), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            // Prime only the OLD viewing hierarchy, before production creates
            // ChooseToolPanel and then the requested numeric panel.
            viewer.contentView?.layoutSubtreeIfNeeded(); viewer.recalculateKeyViewLoop()
            try await enter(viewer, tool: tool)
            let c = viewer.contentRootForTesting.editModeController
            let width: NSTextField, height: NSTextField, apply: NSButton
            var resolutions = 0
            if let panel = c._installedToolForTesting as? ResizePanel {
                width = panel._widthField; height = panel._heightField; apply = panel._applyButton
                let previous = panel.onSpecChanged
                panel.onSpecChanged = { spec in resolutions += 1; previous?(spec) }
            } else {
                let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
                width = panel._widthField; height = panel._heightField; apply = panel._applyButton
                let previous = panel.onDimensionsEdited
                panel.onDimensionsEdited = { w, h, axis in resolutions += 1; previous?(w, h, axis) }
            }
            try draft("768", into: width, in: viewer)
            try installedTab(from: width, in: viewer)
            try await until("Production-installed Width traverses to Height") {
                height.currentEditor() != nil && viewer.firstResponder === height.currentEditor()
            }
            XCTAssertEqual(width.integerValue, 768)
            XCTAssertEqual(height.integerValue, tool == .resize ? 512 : 1024)
            if let panel = c._installedToolForTesting as? ResizePanel {
                XCTAssertEqual(panel._percentField.doubleValue, 50, accuracy: 0.001)
            }
            XCTAssertEqual(resolutions, 1)
            try draft("256", into: height, in: viewer)
            try installedTab(from: height, in: viewer, backwards: true)
            try await until("Production-installed Height traverses back to Width") {
                width.currentEditor() != nil && viewer.firstResponder === width.currentEditor()
            }
            XCTAssertEqual(width.integerValue, tool == .resize ? 384 : 768)
            XCTAssertEqual(height.integerValue, 256)
            XCTAssertEqual(resolutions, 2)
            let session = try XCTUnwrap(c.recipe), before = await session.snapshot()
            XCTAssertTrue(before.isEmpty)
            XCTAssertFalse(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.hasEdits)
            XCTAssertEqual(try Data(contentsOf: url), original)
            apply.performClick(nil); await c.settleForTesting()
            let accepted = await session.snapshot(); XCTAssertEqual(accepted.count, 1)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: tool == .resize ? 384 : 768, height: 256))
            c.performUndo(); await c.settleForTesting()
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 1536, height: 1024))
            c.performRedo(); await c.settleForTesting()
            XCTAssertEqual(c.currentPixelSize, CGSize(width: tool == .resize ? 384 : 768, height: 256))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testProductionToolReplacementAndNoToolReentryRemoveOldKeyViews() async throws {
        let url = try blurFixture("dynamic-replacement.png"), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        viewer.contentView?.layoutSubtreeIfNeeded(); viewer.recalculateKeyViewLoop()
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let old = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        let firstSession = try XCTUnwrap(c.recipe)
        try draft("768", into: old._widthField, in: viewer)
        try installedTab(from: old._widthField, in: viewer)
        try await until("The old Resize panel traverses before replacement") { old._heightField.currentEditor() != nil }
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        try pick(.crop, in: viewer); await c.settleForTesting()
        XCTAssertNil(old.window); XCTAssertNil(old._heightField.window)
        let crop = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        try draft("768", into: crop._widthField, in: viewer)
        try installedTab(from: crop._widthField, in: viewer)
        try await until("Replacement Crop Width reaches its own Height") { crop._heightField.currentEditor() != nil }
        try draft("256", into: crop._heightField, in: viewer)
        try installedTab(from: crop._heightField, in: viewer, backwards: true)
        try await until("Replacement Crop Height returns to its own Width") { crop._widthField.currentEditor() != nil }
        let unchanged = await firstSession.snapshot(); XCTAssertTrue(unchanged.isEmpty)
        c.finalizeExit()
        XCTAssertNil(c.parameterPanel.installed); XCTAssertNil(crop.window)
        viewer.keyDown(with: try key("e", code: 14, modifiers: .command, in: viewer))
        await viewer.waitForEditLoad()
        XCTAssertTrue(c.isActive); XCTAssertNil(c.currentTool)
        XCTAssertTrue(c.parameterPanel.installed is ChooseToolPanel)
        let fresh = try XCTUnwrap(c.recipe)
        XCTAssertFalse(fresh === firstSession)
        try pick(.resize, in: viewer); await c.settleForTesting()
        let replacement = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try draft("768", into: replacement._widthField, in: viewer)
        try installedTab(from: replacement._widthField, in: viewer)
        try await until("Resize after no-tool entry reaches current Height") { replacement._heightField.currentEditor() != nil }
        try draft("256", into: replacement._heightField, in: viewer)
        try installedTab(from: replacement._heightField, in: viewer, backwards: true)
        try await until("Resize after no-tool entry returns to current Width") { replacement._widthField.currentEditor() != nil }
        XCTAssertEqual(replacement.pendingSpec?.width, 384); XCTAssertEqual(replacement.pendingSpec?.height, 256)
        let operations = await fresh.snapshot(); XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testDetachedScrollingPanelRefreshesPrimedWindowLoopOnActualAttachment() async throws {
        _ = NSApplication.shared
        let slot = EditParameterPanel()
        slot.bandHeightProvider = { 160 }
        let resize = ResizePanel(); resize.sourcePixelSize = CGSize(width: 1536, height: 1024)
        slot.install(resize)
        XCTAssertNil(slot.window); XCTAssertTrue(slot.isScrolling)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = outer
        let previous = NSTextField(string: "old hierarchy")
        previous.frame = NSRect(x: 20, y: 20, width: 120, height: 24); outer.addSubview(previous)
        outer.layoutSubtreeIfNeeded(); window.recalculateKeyViewLoop()
        outer.addSubview(slot)
        NSLayoutConstraint.activate([
            slot.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 220),
            slot.topAnchor.constraint(equalTo: outer.topAnchor, constant: 20),
            slot.widthAnchor.constraint(equalToConstant: EditParameterPanel.panelWidth),
            slot.heightAnchor.constraint(equalToConstant: 160),
        ])
        outer.layoutSubtreeIfNeeded() // ordinary attachment layout; no test-side key-loop refresh
        XCTAssertTrue(window.makeFirstResponder(resize._widthField))
        let editor = try XCTUnwrap(resize._widthField.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("768", replacementRange: editor.selectedRange())
        try installedTab(from: resize._widthField, in: window)
        try await until("Attached scrolling Resize reaches Height") { resize._heightField.currentEditor() != nil }
        XCTAssertEqual(resize.pendingSpec?.width, 768); XCTAssertEqual(resize.pendingSpec?.height, 512)
        let heightEditor = try XCTUnwrap(resize._heightField.currentEditor() as? NSTextView)
        heightEditor.selectAll(nil); heightEditor.insertText("256", replacementRange: heightEditor.selectedRange())
        try installedTab(from: resize._heightField, in: window, backwards: true)
        try await until("Attached scrolling Resize returns to Width") { resize._widthField.currentEditor() != nil }
        XCTAssertEqual(resize.pendingSpec?.width, 384); XCTAssertEqual(resize.pendingSpec?.height, 256)
        slot.install(nil)
        XCTAssertNil(resize.window); XCTAssertNil(slot.installed)
    }

    func testFocusedPendingCropLabelsItsActualSaveAndBackupWithoutApplying() async throws {
        let url = try write("pending-crop.png"), neighbor = try write("neighbor.png", red: 0.2)
        let original = try Data(contentsOf: url), untouched = try Data(contentsOf: neighbor)
        let viewer = try await viewer([url, neighbor]); defer { viewer.close() }
        try await enter(viewer, tool: .crop)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        try draft("1200", into: panel._widthField, in: viewer)
        try await until("Focused pending crop describes Save Changes") { c.chromeState.primaryTitle == "Save Changes" }
        XCTAssertNotNil(panel._widthField.currentEditor(), "Caption projection preserves focused editing")
        XCTAssertNil(c.pendingCropRect(), "Reading a focused draft does not move/apply the overlay")
        let operations = await c.recipe?.snapshot(); XCTAssertEqual(operations, [])
        XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.canUndo)
        XCTAssertEqual(c.chromeState.subtitle, "Editing")
        try assertSaveChangesChrome(viewer)
        let capsule = EditCapsuleView(); capsule.apply(c.chromeState)
        XCTAssertEqual(capsule.doneButton.title, "Save Changes")
        XCTAssertEqual(capsule.doneButton.accessibilityLabel(), "Save Changes")
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Labelled crop saves the source") { !c.isActive }
        XCTAssertEqual(try dimensions(url), CGSize(width: 1200, height: 1600))
        XCTAssertEqual(try Data(contentsOf: neighbor), untouched)
        let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).backupURL), original)
    }

    func testFocusedResizeCaptionProjectsLinkedCommitAndSavesThatSize() async throws {
        let url = try write("pending-resize.png")
        let before = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try draft("768", into: panel._widthField, in: viewer)
        try await until("Focused linked resize describes Save Changes") { c.chromeState.primaryTitle == "Save Changes" }
        XCTAssertEqual(panel._heightField.stringValue, "1600", "Caption does not commit the linked field")
        XCTAssertEqual(panel._percentField.stringValue, "100")
        XCTAssertFalse(panel._applyButton.isEnabled)
        XCTAssertNotNil(panel._widthField.currentEditor())
        let operations = await c.recipe?.snapshot(); XCTAssertEqual(operations, [])
        XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.canUndo)
        try assertSaveChangesChrome(viewer)
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Projected linked size saves") { !c.isActive }
        XCTAssertEqual(try dimensions(url), CGSize(width: 768, height: 512))
        let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).backupURL), before)
    }

    func testFocusedResizeInvalidIdentityAndResetKeepHistoryClean() async throws {
        let url = try write("identity-resize.png")
        let before = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try draft("1200", into: panel._widthField, in: viewer)
        try await until("Meaningful draft labels save") { c.chromeState.primaryTitle == "Save Changes" }
        for value in ["2400", "", "invalid", "4800"] {
            try draft(value, into: panel._widthField, in: viewer)
            try await until("Invalid/full/prevent-upscale identity is clean") { c.chromeState.primaryTitle == "Done" }
            XCTAssertNotNil(panel._widthField.currentEditor())
            XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.canUndo)
        }
        panel._resetButton.performClick(nil)
        XCTAssertEqual(c.chromeState.primaryTitle, "Done")
        let clean = await c.recipe?.snapshot(); XCTAssertEqual(clean, [])
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        try draft("invalid", into: panel._widthField, in: viewer)
        XCTAssertEqual(c.chromeState.primaryTitle, "Save Changes", "Earlier applied edits remain dirty")
        XCTAssertTrue(c.chromeState.hasEdits); XCTAssertTrue(c.chromeState.canUndo)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testResetCropButtonKeepsFullDimensionsAndFocusedEditorWithoutDirtying() async throws {
        let url = try write("reset-focused-crop.png")
        let before = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .crop)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        let recipe = try XCTUnwrap(c.recipe), history = await recipe.checkpoint()
        let aspect = panel.aspect, thirds = panel._thirdsCheckbox.state, golden = panel._goldenCheckbox.state
        try draft("1200", into: panel._widthField, in: viewer)
        let editor = try XCTUnwrap(panel._widthField.currentEditor() as? NSTextView)
        panel._resetButton.performClick(nil)
        XCTAssertEqual(panel._widthField.stringValue, "2400")
        XCTAssertEqual(panel._heightField.stringValue, "1600")
        XCTAssertTrue(viewer.firstResponder === editor)
        XCTAssertTrue(panel._widthField.currentEditor() === editor)
        XCTAssertEqual(editor.string, "2400", "The active field editor shows the reset value too")
        XCTAssertNil(c.pendingCropRect())
        XCTAssertEqual(c.cropOverlay._cropRect, c.cropOverlay._imageFrame)
        XCTAssertEqual(c.chromeState.primaryTitle, "Done")
        XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.canRedo)
        XCTAssertEqual(panel.aspect, aspect); XCTAssertEqual(panel._thirdsCheckbox.state, thirds); XCTAssertEqual(panel._goldenCheckbox.state, golden)
        let after = await recipe.checkpoint(); XCTAssertEqual(after, history)
        // The next real field commit still targets width, not a hidden old value.
        try await type("600", into: panel._widthField, in: viewer)
        XCTAssertEqual(try XCTUnwrap(c.pendingCropRect()).width, 0.25, accuracy: 0.001)
        panel._resetButton.performClick(nil)
        var prompts = 0
        EditToolTransitionModal.responderForTesting = { _ in prompts += 1; return .cancel }
        try pick(.color, in: viewer); await c.settleForTesting()
        XCTAssertEqual(c.currentTool, .color); XCTAssertEqual(prompts, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testResetCropShowsCurrentAppliedSizeAndPreservesHistory() async throws {
        let url = try write("reset-after-applied-geometry.png")
        let before = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .crop)
        let c = viewer.contentRootForTesting.editModeController
        let first = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        try await type("1200", into: first._widthField, in: viewer)
        first._applyButton.performClick(nil); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 1200, height: 1600))
        try pick(.resize, in: viewer); await c.settleForTesting()
        let resize = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try await type("600", into: resize._widthField, in: viewer)
        resize._applyButton.performClick(nil); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 600, height: 800))
        try pick(.crop, in: viewer); await c.settleForTesting()
        let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        let recipe = try XCTUnwrap(c.recipe), history = await recipe.checkpoint()
        try draft("300", into: panel._widthField, in: viewer)
        let editor = try XCTUnwrap(panel._widthField.currentEditor() as? NSTextView)
        panel._resetButton.performClick(nil)
        XCTAssertEqual(panel._widthField.stringValue, "600")
        XCTAssertEqual(panel._heightField.stringValue, "800")
        XCTAssertTrue(viewer.firstResponder === editor); XCTAssertEqual(editor.string, "600")
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 600, height: 800))
        XCTAssertNil(c.pendingCropRect())
        XCTAssertEqual(c.chromeState.primaryTitle, "Save Changes")
        let after = await recipe.checkpoint(); XCTAssertEqual(after, history)
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 1200, height: 1600))
        c.performRedo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 600, height: 800))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testFocused16BitResizeLabelsSaveCopyBeforeApplyAndCancelPreservesOriginal() async throws {
        let url = try write16("precision-resize.png")
        let before = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try draft("200", into: panel._widthField, in: viewer)
        try await until("Header-only projected resize requires a copy") { c.chromeState.primaryTitle == "Save Copy…" }
        XCTAssertTrue(c.chromeState.savePolicy.contains("16-bit"))
        XCTAssertNotNil(panel._widthField.currentEditor())
        XCTAssertEqual(panel._heightField.stringValue, "300")
        XCTAssertFalse(panel._applyButton.isEnabled)
        let operations = await c.recipe?.snapshot(); XCTAssertEqual(operations, [])
        let chrome = viewer.contentRootForTesting.editToolbarController
        XCTAssertEqual(chrome.doneButton.title, "Save Copy…")
        XCTAssertEqual(chrome.doneButton.accessibilityLabel(), "Save Copy…")
        let item = try XCTUnwrap(viewer.toolbar?.items.first { $0.view === chrome.doneButton })
        XCTAssertEqual(item.paletteLabel, "Save Copy…")
        XCTAssertEqual(item.menuFormRepresentation?.title, "Save Copy…")
        var panels = 0
        viewer.savePanelResponderForTesting = { _, _ in panels += 1; return nil }
        chrome.doneButton.performClick(nil)
        try await until("Actual copy cancellation keeps editing") { panels == 1 && !c.isSaving }
        XCTAssertTrue(c.isActive)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.bitsPerComponent, 16)
    }

    func testLateProjectedPrecisionCannotReplaceResetDiscardOrNewPhotoPolicy() async throws {
        for outcome in ["reset", "discard", "new-photo"] {
            let url = try write16("stale-\(outcome).png"), next = try write("next-\(outcome).png")
            let before = try Data(contentsOf: url)
            let viewer = try await viewer([url, next]); defer { viewer.close() }
            try await enter(viewer, tool: .resize)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            var release: CheckedContinuation<Void, Never>?
            var held = false, returned = false
            defer { release?.resume() }
            c.capabilityResolverForTesting = { source, operations in
                let capability = ImageExporter.capability(for: source, operations: operations)
                if !held, operations.contains(where: { if case .resize = $0 { true } else { false } }) {
                    held = true
                    await withCheckedContinuation { release = $0 }
                    returned = true
                }
                return capability
            }
            try draft("200", into: panel._widthField, in: viewer)
            try await until("Projected resize response is held") { release != nil }
            switch outcome {
            case "reset": panel._resetButton.performClick(nil)
            case "discard":
                EditToolTransitionModal.responderForTesting = { _ in .discard }
                c.selectTool(.crop); await c.settleForTesting()
            default:
                c.finalizeExit()
                await viewer.navigate(to: 1)
                try await until("Next source is accepted") { viewer.canPerform(.editImage) }
                viewer.enterEditMode(landOn: .crop); await viewer.waitForEditLoad()
            }
            try await until("Current clean policy settles before the old response") {
                c.chromeState.primaryTitle == "Done" && !c.chromeState.requiresCopy && !c.chromeState.savePolicy.contains("16-bit")
            }
            let expected = c.chromeState
            release?.resume(); release = nil
            try await until("Old cancellation-resistant response returns") { returned }
            XCTAssertEqual(c.chromeState, expected)
            XCTAssertFalse(c.chromeState.hasEdits)
            XCTAssertEqual(try Data(contentsOf: url), before)
            c.capabilityResolverForTesting = nil
            EditToolTransitionModal.responderForTesting = { _ in .keep }
        }
    }

    func testFocusedLevelsCaptionPreservesDraftThenPrimarySavesItsExactProjectionOnce() async throws {
        let url = try write("pending-levels.png", red: 0.5), neighbor = try write("levels-neighbor.png", red: 0.2)
        let original = try Data(contentsOf: url), untouched = try Data(contentsOf: neighbor)
        let viewer = try await viewer([url, neighbor]); defer { viewer.close() }
        try await enter(viewer, tool: .levels)
        let content = viewer.contentRootForTesting, c = content.editModeController
        await c.settleForTesting()
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        let field = try XCTUnwrap(panel._field(.inBlack)), session = try XCTUnwrap(c.recipe)
        let checkpoint = await session.checkpoint(), presented = try XCTUnwrap(content.imageView.image)
        try draft("10", into: field, in: viewer)
        let focused = try XCTUnwrap(field.currentEditor())
        try await until("Focused Levels describes its real save action") { c.chromeState.primaryTitle == "Save Changes" }
        XCTAssertTrue(viewer.firstResponder === focused); XCTAssertTrue(field.currentEditor() === focused)
        XCTAssertEqual(panel.params, .identity)
        XCTAssertEqual(panel._handle(.inBlack)?.accessibilityValue() as? String, "0")
        XCTAssertTrue(content.imageView.image === presented, "caption projection does not render")
        let stillUnchanged = await session.checkpoint(); XCTAssertEqual(stillUnchanged, checkpoint)
        XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.canRedo)
        XCTAssertEqual(c.chromeState.subtitle, "Editing")
        try assertSaveChangesChrome(viewer)
        XCTAssertEqual(content.editToolbarController.doneButton.accessibilityLabel(), "Save Changes")
        let capsule = EditCapsuleView(); capsule.apply(c.chromeState)
        XCTAssertEqual(capsule.doneButton.title, "Save Changes")
        XCTAssertEqual(capsule.doneButton.accessibilityLabel(), "Save Changes")
        let projected = try XCTUnwrap(panel.projectedParams)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let originalPixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let expected = await EditRenderer().renderFinal(recipe: EditRecipe(operations: [.levels(projected)]), from: originalPixels)
        content.editToolbarController.doneButton.performClick(nil)
        try await until("Explicit Levels primary saves and exits") { !c.isActive }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        func sample(_ image: CGImage) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 4))
        }
        XCTAssertEqual(try sample(saved), try sample(expected), "actual saved pixels agree with the projected Levels operation")
        XCTAssertNotEqual(try sample(saved), try sample(originalPixels))
        XCTAssertEqual(try dimensions(url), CGSize(width: 2400, height: 1600))
        XCTAssertEqual(try Data(contentsOf: neighbor), untouched)
        let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).backupURL), original)
    }

    func testFocusedLevelsInvalidIdentityChannelAndResetKeepHistoryAndCurrentFocusClean() async throws {
        let url = try write("levels-clean.png", red: 0.5), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .levels)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        let field = try XCTUnwrap(panel._field(.inBlack)), session = try XCTUnwrap(c.recipe)
        let checkpoint = await session.checkpoint()
        try draft("10", into: field, in: viewer)
        try await until("Meaningful Levels draft labels save") { c.chromeState.primaryTitle == "Save Changes" }
        let originalEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(viewer.firstResponder === originalEditor)
        XCTAssertEqual(panel.params, .identity)
        let beforeReplacements = await session.checkpoint(); XCTAssertEqual(beforeReplacements, checkpoint)
        for value in ["0", "", "invalid", "nan", "inf", "-1e100", "0.49"] {
            XCTAssertTrue(viewer.firstResponder === originalEditor, "before \(value)")
            XCTAssertTrue(field.currentEditor() === originalEditor, "before \(value)")
            XCTAssertEqual(panel.params, .identity, "before \(value)")
            let before = await session.checkpoint(); XCTAssertEqual(before, checkpoint, "before \(value)")
            try draft(value, into: field, in: viewer)
            try await until("No-op or invalid Levels text is clean") { c.chromeState.primaryTitle == "Done" }
            XCTAssertNotNil(field.currentEditor()); XCTAssertFalse(c.chromeState.hasEdits)
            XCTAssertTrue(viewer.firstResponder === originalEditor, "after \(value)")
            XCTAssertTrue(field.currentEditor() === originalEditor, "after \(value)")
            XCTAssertEqual(panel.params, .identity, "after \(value)")
            let after = await session.checkpoint(); XCTAssertEqual(after, checkpoint, "after \(value)")
        }
        try draft("10", into: field, in: viewer)
        let focused = try XCTUnwrap(field.currentEditor() as? NSTextView)
        panel.setChannel(.red)
        try await until("Changing channel clears the old focused projection") { c.chromeState.primaryTitle == "Done" }
        XCTAssertTrue(viewer.firstResponder === focused); XCTAssertEqual(focused.string, "0")
        XCTAssertNil(panel.projectedParams); XCTAssertEqual(panel.params, .identity)
        try draft("20", into: field, in: viewer)
        XCTAssertEqual(panel.projectedParams?.red.inBlack, 20)
        panel._resetButton.performClick(nil); await c.settleForTesting()
        XCTAssertEqual(c.chromeState.primaryTitle, "Done"); XCTAssertEqual(focused.string, "0")
        XCTAssertTrue(viewer.firstResponder === focused)
        let unchanged = await session.checkpoint(); XCTAssertEqual(unchanged, checkpoint)
        viewer.makeFirstResponder(nil)
        _ = field.sendAction(field.action, to: field.target)
        await c.settleForTesting()
        XCTAssertEqual(panel.params, .identity, "later commitment cannot revive discarded text")
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        try draft("invalid", into: field, in: viewer)
        XCTAssertEqual(c.chromeState.primaryTitle, "Save Changes")
        XCTAssertTrue(c.chromeState.hasEdits); XCTAssertTrue(c.chromeState.canUndo)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFocused16BitLevelsLabelsSharedCopyPolicyAndCancellationPreservesSource() async throws {
        let url = try write16("precision-levels.png"), original = try Data(contentsOf: url)
        let header = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(header, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .levels)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        let field = try XCTUnwrap(panel._field(.inBlack))
        try draft("0", into: field, in: viewer)
        try await until("Identity Levels does not invent conversion") { c.chromeState.primaryTitle == "Done" && !c.chromeState.requiresCopy }
        try draft("10", into: field, in: viewer)
        try await until("Focused Levels uses the shared precision decision") { c.chromeState.primaryTitle == "Save Copy…" }
        let projected = try XCTUnwrap(panel.projectedParams)
        let capability = ImageExporter.capability(for: url, operations: [.levels(projected)])
        XCTAssertEqual(c.chromeState.savePolicy, capability.conversionDisclosure)
        XCTAssertTrue(c.chromeState.savePolicy.contains("16-bit")); XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(panel.params, .identity)
        let operations = await c.recipe?.snapshot(); XCTAssertEqual(operations, [])
        let chrome = viewer.contentRootForTesting.editToolbarController
        XCTAssertEqual(chrome.doneButton.title, "Save Copy…")
        XCTAssertEqual(chrome.doneButton.accessibilityLabel(), "Save Copy…")
        let item = try XCTUnwrap(viewer.toolbar?.items.first { $0.view === chrome.doneButton })
        XCTAssertEqual(item.paletteLabel, "Save Copy…"); XCTAssertEqual(item.menuFormRepresentation?.title, "Save Copy…")
        let capsule = EditCapsuleView(); capsule.apply(c.chromeState)
        XCTAssertEqual(capsule.doneButton.title, "Save Copy…")
        var panels = 0
        viewer.savePanelResponderForTesting = { _, _ in panels += 1; return nil }
        chrome.doneButton.performClick(nil)
        try await until("Copy destination Cancel leaves Levels editing") { panels == 1 && !c.isSaving }
        XCTAssertTrue(c.isActive); XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(header, 0, nil)?.bitsPerComponent, 16)
    }

    func testLateLevelsProjectionCannotReplaceIdentityResetChannelDiscardOrNewPhotoPolicy() async throws {
        for outcome in ["identity", "reset", "channel", "discard", "new-photo"] {
            let url = try write16("levels-stale-\(outcome).png"), next = try write("levels-next-\(outcome).png")
            let original = try Data(contentsOf: url)
            let viewer = try await viewer([url, next]); defer { viewer.close() }
            try await enter(viewer, tool: .levels)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
            let field = try XCTUnwrap(panel._field(.inBlack))
            var release: CheckedContinuation<Void, Never>?
            var held = false, returned = false
            defer { release?.resume() }
            c.capabilityResolverForTesting = { source, operations in
                let capability = ImageExporter.capability(for: source, operations: operations)
                if !held, operations.contains(where: { if case .levels(let p) = $0 { !p.isIdentity } else { false } }) {
                    held = true
                    await withCheckedContinuation { release = $0 }
                    returned = true
                }
                return capability
            }
            try draft("10", into: field, in: viewer)
            try await until("Projected Levels capability is held") { release != nil }
            switch outcome {
            case "identity": try draft("0", into: field, in: viewer)
            case "reset": panel._resetButton.performClick(nil)
            case "channel": panel.setChannel(.red)
            case "discard":
                EditToolTransitionModal.responderForTesting = { _ in .discard }
                c.selectTool(.crop); await c.settleForTesting()
            default:
                c.finalizeExit(); await viewer.navigate(to: 1)
                try await until("New source is accepted") { viewer.canPerform(.editImage) }
                viewer.enterEditMode(landOn: .crop); await viewer.waitForEditLoad()
            }
            try await until("Current policy wins before stale Levels response returns") {
                c.chromeState.primaryTitle == "Done" && !c.chromeState.requiresCopy && !c.chromeState.savePolicy.contains("16-bit")
            }
            let current = c.chromeState
            release?.resume(); release = nil
            try await until("Cancellation-resistant old Levels response returns") { returned }
            XCTAssertEqual(c.chromeState, current); XCTAssertFalse(c.chromeState.hasEdits)
            XCTAssertEqual(try Data(contentsOf: url), original)
            c.capabilityResolverForTesting = nil
            EditToolTransitionModal.responderForTesting = { _ in .keep }
        }
    }

    func testFocusedLevelsToolAndPhotoDecisionsKeepDiscardOrCancelWithoutImplicitWrites() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
            let url = try write("levels-tool-\(choice).png", red: 0.5), original = try Data(contentsOf: url)
            let viewer = try await viewer([url]); defer { viewer.close() }
            try await enter(viewer, tool: .levels)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
            try draft("10", into: try XCTUnwrap(panel._field(.inBlack)), in: viewer)
            var prompts = 0
            EditToolTransitionModal.responderForTesting = { content in
                prompts += 1; XCTAssertEqual(content.outgoing, .levels); return choice
            }
            try pick(.color, in: viewer); await c.settleForTesting()
            XCTAssertEqual(prompts, 1)
            XCTAssertEqual(c.currentTool, choice == .cancel ? .levels : .color)
            let operations = await c.recipe?.snapshot()
            XCTAssertEqual(operations?.count, choice == .discard ? 0 : 1)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        for choice in [EditExitModal.Choice.cancel, .discard] {
            let url = try write("levels-photo-\(choice).png", red: 0.5), next = try write("levels-photo-next-\(choice).png")
            let original = try Data(contentsOf: url), neighbor = try Data(contentsOf: next)
            let viewer = try await viewer([url, next]); defer { viewer.close() }
            try await enter(viewer, tool: .levels)
            let c = viewer.contentRootForTesting.editModeController
            let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
            try draft("10", into: try XCTUnwrap(panel._field(.inBlack)), in: viewer)
            var prompts = 0
            EditExitModal.responderForTesting = { _ in prompts += 1; return choice }
            viewer.dispatch(.nextImage); await viewer.waitForEditExit()
            XCTAssertEqual(prompts, 1)
            if choice == .cancel {
                XCTAssertTrue(c.isActive); XCTAssertEqual(viewer.displayedItem?.group.primary, url)
                XCTAssertEqual(c.chromeState.primaryTitle, "Save Changes")
            } else {
                try await until("Discard continues to the next photo") { viewer.displayedItem?.group.primary == next }
                XCTAssertFalse(c.isActive)
            }
            XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(try Data(contentsOf: next), neighbor)
        }
    }

    func testLevelsFirstNumericReturnCommitsEachFieldAndChannelBeforeSeparateToolbarSave() async throws {
        for channel in [LevelsPanelChannel.rgb, .red] {
            for (kind, text, expected) in [(LevelsHandleKind.inBlack, "10", 10.0), (.gamma, "1,23", 1.23),
                                            (.inWhite, "200", 200.0), (.outBlack, "10", 10.0), (.outWhite, "200", 200.0)] {
                try await verifyLevelsReturns(channel: channel, kind: kind, text: text, expected: expected, fullscreenHost: false)
            }
        }
        try await verifyLevelsReturns(channel: .green, kind: .inBlack, text: "10", expected: 10, fullscreenHost: true)
    }

    private func verifyLevelsReturns(channel: LevelsPanelChannel, kind: LevelsHandleKind,
                                     text: String, expected: Double, fullscreenHost: Bool) async throws {
        let url = try write("return-\(channel)-\(kind)-\(fullscreenHost).png", red: 0.5)
        let original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        let content = viewer.contentRootForTesting
        if fullscreenHost { content.windowMode = .fullscreen }
        try await enter(viewer, tool: .levels)
        let c = content.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        panel.setChannel(channel)
        let field = try XCTUnwrap(panel._field(kind))
        let primary = fullscreenHost ? content.editCapsule.doneButton : content.editToolbarController.doneButton
        XCTAssertEqual(primary.keyEquivalent, "\r", "real primary remains available to the later independent Return")
        var saveRequests = 0
        let ordinarySave = c.onSaveRequested
        c.onSaveRequested = { saveRequests += 1; ordinarySave?() }
        try draft(text, into: field, in: viewer)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        viewer.sendEvent(try key("\r", code: 36, in: viewer))
        XCTAssertTrue(field.currentEditor() === editor, "owned command is consumed before ordinary deferred commitment")
        XCTAssertEqual(panel.params, .identity, "the consumed command does not synchronously run Return fallback")
        XCTAssertEqual(saveRequests, 0)
        try await until("First numeric Return finishes ordinary field validation only") { field.currentEditor() == nil }
        await c.settleForTesting()
        XCTAssertTrue(c.isActive); XCTAssertEqual(saveRequests, 0)
        XCTAssertEqual(LevelsRules.value(kind, of: panel.params[channel]), expected, accuracy: 0.001)
        for other in LevelsPanelChannel.allCases where other != channel { XCTAssertTrue(panel.params[other].isIdentity) }
        let session = try XCTUnwrap(c.recipe), operations = await session.snapshot()
        XCTAssertEqual(operations.count, 1, "normal end-edit plus idempotent explicit action produce one changed step")
        XCTAssertEqual(EditRecipe.effectiveLevels(operations), panel.params)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let noBackups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertTrue(noBackups.isEmpty)
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(panel.params, .identity, "one Undo restores the prior effective Levels")
        c.performRedo(); await c.settleForTesting()
        XCTAssertEqual(LevelsRules.value(kind, of: panel.params[channel]), expected, accuracy: 0.001)
        viewer.sendEvent(try key("\r", code: 36, in: viewer))
        try await until("A distinct later Return uses the genuine primary save route") { !c.isActive }
        XCTAssertEqual(saveRequests, 1)
        let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first).backupURL), original)
    }

    func testLevelsNumericReturnInvalidIdentityAndPriorDirtyRecipeStayUnsaved() async throws {
        let url = try write("return-invalid-levels.png", red: 0.5), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .levels)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        let field = try XCTUnwrap(panel._field(.inBlack)), session = try XCTUnwrap(c.recipe)
        for value in ["invalid", "", "0"] {
            try draft(value, into: field, in: viewer)
            viewer.sendEvent(try key("\r", code: 36, in: viewer))
            try await until("Invalid/no-op numeric Return releases only its field") { field.currentEditor() == nil }
            await c.settleForTesting()
            XCTAssertTrue(c.isActive); XCTAssertEqual(panel.params, .identity)
            XCTAssertEqual(field.stringValue, "0"); XCTAssertEqual(c.chromeState.primaryTitle, "Done")
            let operations = await session.snapshot(); XCTAssertTrue(operations.isEmpty)
        }
        try await type("10", into: field, in: viewer)
        await c.settleForTesting()
        let before = await session.checkpoint()
        try draft("invalid", into: field, in: viewer)
        viewer.sendEvent(try key("\r", code: 36, in: viewer))
        try await until("Invalid text restores the earlier committed Levels value") { field.currentEditor() == nil }
        await c.settleForTesting()
        XCTAssertTrue(c.isActive); XCTAssertEqual(panel.params.master.inBlack, 10)
        XCTAssertEqual(field.stringValue, "10"); XCTAssertEqual(c.chromeState.primaryTitle, "Save Changes")
        let after = await session.checkpoint(); XCTAssertEqual(after, before)
        c.performUndo(); await c.settleForTesting(); XCTAssertEqual(panel.params, .identity)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let backups = await BackupStore(root: root.appendingPathComponent("backups")).records(for: url)
        XCTAssertTrue(backups.isEmpty)
    }

    func testMovingBetweenLevelsFieldsCommitsTheFirstAndKeepsTheSecondFocusedDraft() async throws {
        let url = try write("levels-ordinary-focus.png", red: 0.5), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .levels)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        let black = try XCTUnwrap(panel._field(.inBlack)), gamma = try XCTUnwrap(panel._field(.gamma))
        try draft("10", into: black, in: viewer)
        try draft("1.23", into: gamma, in: viewer)
        await c.settleForTesting()
        XCTAssertEqual(panel.params.master.inBlack, 10)
        XCTAssertEqual(panel.params.master.gamma, 1)
        XCTAssertEqual(panel.projectedParams?.master.gamma, 1.23)
        XCTAssertTrue(viewer.firstResponder === gamma.currentEditor())
        XCTAssertTrue(c.chromeState.hasEdits); XCTAssertTrue(c.chromeState.canUndo)
        let operations = await c.recipe?.snapshot(); XCTAssertEqual(operations?.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTypedCropReturnThenColorThenPrimarySavesCropToDisk() async throws {
        let url = try write("01-Crop-Color.png")
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .crop)
        let editor = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(editor._installedToolForTesting as? CropPanel)
        try await type("1200", into: panel._widthField, in: viewer)
        XCTAssertEqual(try XCTUnwrap(editor.pendingCropRect()).width, 0.5, accuracy: 0.001)
        try pick(.color, in: viewer); await editor.settleForTesting()
        XCTAssertTrue(editor.hasPendingEdits)
        try assertSaveChangesChrome(viewer)
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Crop saves and leaves editing") { !editor.isActive }
        XCTAssertEqual(try dimensions(url), CGSize(width: 1200, height: 1600))
    }

    func testCleanEditExitThenRightThenTypedResizeSavesOnlyCurrentPhoto() async throws {
        let first = try write("01-Crop-Color.png", red: 0.2), second = try write("02-Resize-Color.png", red: 0.8)
        let originalFirst = try Data(contentsOf: first), originalSecond = try Data(contentsOf: second)
        XCTAssertNotEqual(originalFirst, originalSecond, "Fixtures have distinct pixels as well as distinct paths")
        XCTAssertEqual(try dimensions(second), CGSize(width: 2400, height: 1600))
        let viewer = try await viewer([first, second]); defer { viewer.close() }
        try await enter(viewer, tool: .crop)
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Clean Done leaves editing") { !viewer.contentRootForTesting.isEditModeActive }
        viewer.keyDown(with: try key(SpecialKey.right, code: 124, in: viewer))
        try await until("Right displays the second actual photo") {
            viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == second
                && viewer.imageViewForTesting.sourceID == FileImageSource(url: second).id
        }
        try await enter(viewer, tool: .resize)
        let editor = viewer.contentRootForTesting.editModeController
        XCTAssertEqual(editor.sourceURL, second)
        let panel = try XCTUnwrap(editor._installedToolForTesting as? ResizePanel)
        try await type("1200", into: panel._widthField, in: viewer)
        XCTAssertEqual(panel._heightField.integerValue, 800)
        try pick(.color, in: viewer); await editor.settleForTesting()
        try assertSaveChangesChrome(viewer)
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Resize saves and leaves editing") { !editor.isActive }
        XCTAssertEqual(try Data(contentsOf: first), originalFirst, "The preceding photo must remain byte-identical")
        XCTAssertNotEqual(try Data(contentsOf: second), originalSecond)
        XCTAssertEqual(try dimensions(second), CGSize(width: 1200, height: 800))
    }
    func testSaveRefusesDivergentDisplayedPhotoAndKeepsEdits() async throws {
        let first = try write("01-edit-source.png", red: 0.2), second = try write("02-display.png", red: 0.8)
        let originalFirst = try Data(contentsOf: first), originalSecond = try Data(contentsOf: second)
        let viewer = try await viewer([first, second]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let editor = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(editor._installedToolForTesting as? ResizePanel)
        try await type("1200", into: panel._widthField, in: viewer)
        try pick(.color, in: viewer); await editor.settleForTesting()
        let recipe = try XCTUnwrap(editor.recipe), operations = await recipe.snapshot()
        // Deliberately bypass the UI exit guard to model an accidental late navigation paint.
        // This checks save's independent safety boundary rather than relying on entry rejection.
        await viewer.navigate(to: 1)
        XCTAssertEqual(viewer.displayedItem?.group.primary, second)
        XCTAssertEqual(editor.sourceURL, first)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message,
                       "The photo on screen no longer matches this edit. Your edits are still open. No file was changed.")
        XCTAssertTrue(editor.isActive); XCTAssertTrue(editor.recipe === recipe)
        let retainedOperations = await recipe.snapshot()
        XCTAssertEqual(retainedOperations, operations)
        XCTAssertEqual(try Data(contentsOf: first), originalFirst)
        XCTAssertEqual(try Data(contentsOf: second), originalSecond)
    }

    func testRightThenImmediateEditCannotBindToPreviousPhoto() async throws {
        try await pendingNavigationEdit(waitForIntent: false)
    }

    func testEditDuringHeldNextDecodeCannotBindToPreviousPhoto() async throws {
        try await pendingNavigationEdit(waitForIntent: true)
    }

    private func pendingNavigationEdit(waitForIntent: Bool) async throws {
        let first = try write("01-previous.png", red: 0.2), second = try write("02-requested.png", red: 0.8)
        let originalFirst = try Data(contentsOf: first), originalSecond = try Data(contentsOf: second)
        let gate = HeldNextPhoto()
        let viewer = try await viewer([first, second], sources: [FileImageSource(url: first), HeldNextPhotoSource(url: second, gate: gate)])
        defer { viewer.close() }
        let editor = viewer.contentRootForTesting.editModeController
        do {
        // Match the native preceding clean edit/Done before requesting the next image.
        try await enter(viewer, tool: .crop)
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Clean edit exits") { !viewer.contentRootForTesting.isEditModeActive }
        viewer.keyDown(with: try key(SpecialKey.right, code: 124, in: viewer))
        if waitForIntent {
            try await until("Next navigation starts while its actual image is held") { viewer.intent.currentIndex == 1 }
            XCTAssertEqual(viewer.displayedItem?.group.primary, first)
        }
        viewer.keyDown(with: try key("e", code: 14, modifiers: .command, in: viewer))
        await viewer.waitForEditLoad()
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message,
                       "Wait for the current photo to finish loading before editing.")
        XCTAssertEqual(try Data(contentsOf: first), originalFirst)
        XCTAssertEqual(try Data(contentsOf: second), originalSecond)
        XCTAssertFalse(editor.isActive, "Editing during queued/in-flight navigation must not bind the preceding photo")
        // Resume next-image work before any later throwing assertion/cleanup.
        await gate.release()
        try await until("The requested next photo is displayed") {
            viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == second
                && viewer.imageViewForTesting.sourceID == FileImageSource(url: second).id
        }
        XCTAssertFalse(editor.isActive, "A late navigation paint must never leave the preceding file's edit session active")
        try await enter(viewer, tool: .resize)
        XCTAssertEqual(editor.sourceURL, second)
        let panel = try XCTUnwrap(editor._installedToolForTesting as? ResizePanel)
        try await type("1200", into: panel._widthField, in: viewer)
        try pick(.color, in: viewer); await editor.settleForTesting()
        viewer.contentRootForTesting.editToolbarController.doneButton.performClick(nil)
        try await until("Only the requested photo is saved") { !editor.isActive }
        XCTAssertEqual(try Data(contentsOf: first), originalFirst, "The preceding photo must remain byte-identical")
        XCTAssertNotEqual(try Data(contentsOf: second), originalSecond)
        XCTAssertEqual(try dimensions(second), CGSize(width: 1200, height: 800))
        } catch {
            await gate.release()
            throw error
        }
    }


    private final class RefusingNumericEndDelegate: NSObject, NSTextFieldDelegate {
        weak var original: (any NSTextFieldDelegate)?
        var refuses = true
        var refusals = 0
        init(original: (any NSTextFieldDelegate)?) { self.original = original }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            if refuses { refusals += 1; return false }
            return original?.control?(control, textShouldEndEditing: fieldEditor) ?? true
        }
        func controlTextDidBeginEditing(_ notification: Notification) { original?.controlTextDidBeginEditing?(notification) }
        func controlTextDidChange(_ notification: Notification) { original?.controlTextDidChange?(notification) }
        func controlTextDidEndEditing(_ notification: Notification) { original?.controlTextDidEndEditing?(notification) }
    }

    func testRefusedNumericCompletionAbortsToolExitSaveAndReset() async throws {
        let oldToolResponder = EditToolTransitionModal.responderForTesting
        let oldExitResponder = EditExitModal.responderForTesting
        defer {
            EditToolTransitionModal.responderForTesting = oldToolResponder
            EditExitModal.responderForTesting = oldExitResponder
        }
        for route in ["tool", "exit", "save", "reset"] {
            let url = try blurFixture("refused-\(route).png"), originalBytes = try Data(contentsOf: url)
            let viewer = try await viewer([url])
            let c = viewer.contentRootForTesting.editModeController
            try await enter(viewer, tool: .resize)
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            try await type("1200", into: panel._widthField, in: viewer)
            panel._applyButton.performClick(nil); await c.settleForTesting()
            let session = try XCTUnwrap(c.recipe), before = await session.snapshot()
            XCTAssertEqual(before.count, 1)
            try draft("768", into: panel._widthField, in: viewer)
            let editor = try XCTUnwrap(panel._widthField.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 1, length: 1))
            let originalDelegate = panel._widthField.delegate
            let refusal = RefusingNumericEndDelegate(original: originalDelegate)
            panel._widthField.delegate = refusal
            defer { refusal.refuses = false; panel._widthField.delegate = originalDelegate; viewer.close() }
            var resolutions = 0, prompts = 0, saves = 0
            let previous = panel.onSpecChanged
            panel.onSpecChanged = { spec in resolutions += 1; previous?(spec) }
            EditToolTransitionModal.responderForTesting = { _ in prompts += 1; return .keep }
            EditExitModal.responderForTesting = { _ in prompts += 1; return .cancel }
            c.onSaveRequested = { saves += 1 }
            XCTAssertFalse(viewer.makeFirstResponder(nil), "The native validation delegate really refuses resignation")
            XCTAssertTrue(viewer.firstResponder === editor)
            switch route {
            case "tool": c.selectTool(.color)
            case "exit":
                var outcome: EditExitOutcome?
                c.attemptExit(reason: .userToggled) { outcome = $0 }
                try await until("Refused exit returns its cancelled outcome") { outcome != nil }
                XCTAssertEqual(outcome, .cancelled)
            case "save":
                let prepared = await c.prepareForSave()
                XCTAssertFalse(prepared, "Refused focus must veto save preparation")
            default: c.revertPendingEdits()
            }
            await c.settleForTesting()
            XCTAssertGreaterThanOrEqual(refusal.refusals, 2)
            XCTAssertTrue(c.isActive); XCTAssertEqual(c.currentTool, .resize)
            XCTAssertTrue(c._installedToolForTesting === panel)
            XCTAssertTrue(c.recipe === session)
            let after = await session.snapshot()
            XCTAssertEqual(after, before, "Refused completion must not mutate the recipe")
            XCTAssertEqual(resolutions, 0, "Refused completion must not dispatch a fallback action")
            XCTAssertEqual(prompts, 0); XCTAssertEqual(saves, 0)
            XCTAssertTrue(panel._widthField.currentEditor() === editor)
            XCTAssertTrue(viewer.firstResponder === editor)
            XCTAssertEqual(editor.string, "768")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        }
    }

    func testImmediateReturnThenToolFlushHasOneCommitAndOneHistoryOperation() async throws {
        let url = try blurFixture("return-immediate-flush.png"), original = try Data(contentsOf: url)
        let viewer = try await viewer([url]); defer { viewer.close() }
        try await enter(viewer, tool: .resize)
        let c = viewer.contentRootForTesting.editModeController
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        try draft("768", into: panel._widthField, in: viewer)
        var resolutions = 0
        let previous = panel.onSpecChanged
        panel.onSpecChanged = { spec in resolutions += 1; previous?(spec) }
        viewer.sendEvent(try key("\r", code: 36, in: viewer))
        XCTAssertEqual(resolutions, 1)
        XCTAssertNotNil(panel._widthField.currentEditor(), "This flush precedes the deferred Return resignation")
        c.selectTool(.color)
        await c.settleForTesting()
        try await until("The accepted resize switches to Color") { c.currentTool == .color && !c.isTransitioning }
        XCTAssertEqual(resolutions, 1, "The explicit flush must not recommit the completed Return")
        let session = try XCTUnwrap(c.recipe), operations = await session.snapshot()
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 768, height: 512))
        let replacementFocus = viewer.firstResponder
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(viewer.firstResponder === replacementFocus)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCleanNumericRefocusCancellationAndEditingBackToOriginalValue() throws {
        let panel = ResizePanel(); panel.sourcePixelSize = CGSize(width: 1536, height: 1024)
        let host = EditParameterPanel(); host.install(panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.makeFirstResponder(nil); window.close() }
        let field = panel._widthField
        var resolutions = 0
        panel.onSpecChanged = { _ in resolutions += 1 }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(resolutions, 0, "Untouched native refocus is not a numeric edit")
        XCTAssertTrue(window.makeFirstResponder(field))
        var editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("768", replacementRange: editor.selectedRange())
        XCTAssertTrue(field.abortEditing())
        XCTAssertEqual(resolutions, 0, "Native cancellation is not a commit")
        field.stringValue = "1536"
        XCTAssertTrue(window.makeFirstResponder(field))
        editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("768", replacementRange: editor.selectedRange())
        editor.selectAll(nil); editor.insertText("1536", replacementRange: editor.selectedRange())
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(resolutions, 1, "Actual edits still commit when the final numeric value equals its starting value")
        XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(resolutions, 1, "A later untouched focus cycle stays clean")
    }

    func testDeferredReturnCannotResignANewDraftInTheSameField() async throws {
        let panel = ResizePanel(); panel.sourcePixelSize = CGSize(width: 1536, height: 1024)
        let host = EditParameterPanel(); host.install(panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.makeFirstResponder(nil); window.close() }
        let field = panel._widthField
        XCTAssertTrue(window.makeFirstResponder(field))
        var editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("768", replacementRange: editor.selectedRange())
        var resolutions = 0; panel.onSpecChanged = { _ in resolutions += 1 }
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        XCTAssertEqual(resolutions, 1)
        XCTAssertTrue(window.makeFirstResponder(nil)); XCTAssertTrue(window.makeFirstResponder(field))
        editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("384", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(field.currentEditor() === editor); XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "384"); XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(resolutions, 1)
        XCTAssertTrue(window.makeFirstResponder(nil)); XCTAssertEqual(resolutions, 2)
    }

    func testPercentFieldSelectionAndCaretStayBeforeTheSuffix() throws {
        func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        for larger in [false, true] {
            Prefs.largerChrome = larger
            let panel = ResizePanel()
            panel.sourcePixelSize = CGSize(width: 400, height: 300)
            let host = EditParameterPanel()
            host.install(panel)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.makeFirstResponder(nil); window.close() }
            host.layoutSubtreeIfNeeded()
            let field = panel._percentField
            let suffix = try XCTUnwrap(fields(in: panel).first { $0.stringValue == "%" })
            let suffixRect = field.convert(suffix.bounds, from: suffix)
            for value in ["100", "100.0", "999999999999999"] {
                _ = window.makeFirstResponder(nil)
                field.stringValue = value
                XCTAssertTrue(window.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.selectAll(nil)
                XCTAssertEqual(editor.selectedRange().length, value.utf16.count)
                let visible = editor.convert(editor.visibleRect, to: field)
                XCTAssertLessThanOrEqual(visible.maxX + 2, suffixRect.minX,
                                         "The selected editor viewport must exclude the percent suffix")
                let displayRect = try XCTUnwrap(field.cell).drawingRect(forBounds: field.bounds)
                XCTAssertEqual(visible.maxX, displayRect.maxX, accuracy: 2,
                               "The native editor viewport matches the numeric field text area")
                if value.count <= 5 {
                    let measured = (value as NSString).size(withAttributes: [.font: try XCTUnwrap(field.font)]).width
                    XCTAssertGreaterThanOrEqual(visible.width, measured + 1,
                                               "Common values must fit in the editing viewport too")
                }
                editor.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
                editor.scrollRangeToVisible(editor.selectedRange())
                if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
                let screenCaret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let caret = field.convert(window.convertFromScreen(screenCaret), from: nil)
                XCTAssertLessThanOrEqual(caret.maxX + 1, suffixRect.minX,
                                         "The insertion caret must remain on the numeric side of the unit")
                XCTAssertEqual(editor.string, value)
            }
        }
    }

}


private actor HeldNextPhoto {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() {
        open = true
        let pending = waiting; waiting = []
        for continuation in pending { continuation.resume() }
    }
}

private struct HeldNextPhotoSource: ImageSource {
    let url: URL
    let gate: HeldNextPhoto
    var id: String { FileImageSource(url: url).id }
    var displayName: String { url.lastPathComponent }
    var fileSize: Int64? { FileImageSource(url: url).fileSize }
    var mtime: Date? { FileImageSource(url: url).mtime }
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        await gate.wait()
        return try await FileImageSource(url: url).loadCGImage(maxPixelSize: maxPixelSize)
    }
    func loadProperties() async throws -> ImageProperties { try await FileImageSource(url: url).loadProperties() }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

}

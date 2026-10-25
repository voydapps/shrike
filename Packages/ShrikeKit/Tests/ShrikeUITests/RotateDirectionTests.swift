//
//  RotateDirectionTests.swift
//  ShrikeUITests
//
//  Rotate Left turns the photo counter-clockwise on screen,
//  the same way the file is written, and the view after any mix of turns
//  and flips shows what `ExifOrientation` gives for the same presses.
//  Before the fix, `clipSpaceTransform` turned a positive angle
//  counter-clockwise, so Rotate Left turned the view right.
//
//  Photos are four coloured quadrants: top-left red, top-right green,
//  bottom-left blue, bottom-right yellow. A check reads the colour in each
//  screen corner, so a mirror can't pass for a turn.
//

import XCTest
import AppKit
import ImageIO
import simd
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering

@MainActor
final class RotateDirectionTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-rotdir-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
    }

    override func tearDown() async throws {
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// Screen / image corners in reading order: TL, TR, BL, BR.
    typealias Corners = [String]
    static let upright: Corners = ["red", "green", "blue", "yellow"]
    /// Rotate Left (counter-clockwise): the top-right corner comes to the top-left.
    static let turnedLeft: Corners = ["green", "yellow", "red", "blue"]
    /// Rotate Right (clockwise): the bottom-left corner comes to the top-left.
    static let turnedRight: Corners = ["blue", "red", "yellow", "green"]

    static func quadrants(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // CGContext is y-up: the top rows are the upper half.
        let fills: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: h, width: w, height: h), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: w, y: h, width: w, height: h), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: w, height: h), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: w, y: 0, width: w, height: h), CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
        ]
        for (rect, colour) in fills {
            ctx.setFillColor(colour)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    /// RGBA of the pixel at (x, y), y from the top.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return out
    }

    static func name(_ rgba: [UInt8]) -> String {
        let r = rgba[0] > 128, g = rgba[1] > 128, b = rgba[2] > 128
        switch (r, g, b) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, false): return "yellow"
        default: return "?(\(rgba))"
        }
    }

    /// Colours at the centres of the four quadrants of `image`.
    static func corners(of image: CGImage) -> Corners {
        let w = image.width, h = image.height
        return [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
            .map { name(pixel(image, $0.0, $0.1)) }
    }

    /// Where the view puts the texture's corners: the colour in each screen
    /// corner, for a texture that holds `texture` (the quadrant colours of
    /// the photo as decoded). The quad's (-1, +1) vertex samples uv (0, 0),
    /// the texture's top-left; clip space is y-up.
    static func screenCorners(_ m: simd_float4x4, texture: Corners = upright) -> Corners {
        let vertices: [(SIMD4<Float>, String)] = [
            (SIMD4(-1, 1, 0, 1), texture[0]), (SIMD4(1, 1, 0, 1), texture[1]),
            (SIMD4(-1, -1, 0, 1), texture[2]), (SIMD4(1, -1, 0, 1), texture[3]),
        ]
        var out = Array(repeating: "?", count: 4)
        // Relative to the quad's centre: pan and fit offsets move it.
        let centre = m * SIMD4<Float>(0, 0, 0, 1)
        for (v, colour) in vertices {
            let p = m * v - centre
            let slot = (p.y > 0 ? 0 : 2) + (p.x < 0 ? 0 : 1)
            out[slot] = colour
        }
        return out
    }

    /// Writes a JPEG whose *displayed* picture is the quadrants, stored
    /// with EXIF `orientation` (the stored pixels are turned to match).
    @discardableResult
    static func writeQuadrantJPEG(_ url: URL, orientation: ExifOrientation) -> Bool {
        // Stored pixels S with apply(orientation, S) = quadrants.
        let inverse = ExifOrientation.allCases.first {
            corners(of: ExifOrientation.apply(orientation, to: ExifOrientation.apply($0, to: quadrants()))) == upright
                && ExifOrientation.apply($0, to: quadrants()).width == (orientation.swapsDimensions ? 48 : 64)
        } ?? .up
        let stored = ExifOrientation.apply(inverse, to: quadrants())
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(dest, stored, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// The file's picture as ImageIO shows it (EXIF orientation applied).
    static func displayedPicture(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private func viewer(_ urls: [URL]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: 800, height: 600))
        viewer.markDisplayedForTesting(0)
        // The decoded picture (orientation applied) is the quadrants.
        viewer.imageViewForTesting.image = Self.quadrants()
        return viewer
    }

    private func shown(_ viewer: ViewerWindow) -> Corners {
        Self.screenCorners(viewer.imageViewForTesting.clipSpaceTransform())
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> KeyEventSnapshot {
        KeyEventSnapshot.from(KeyCharactersTests.key(chars, keyCode: code, flags), isKeyUp: false)
    }

    private func contextItem(_ viewer: ViewerWindow, _ title: String) throws -> Int {
        viewer.contextMenu.prepareForTesting()
        return try XCTUnwrap(viewer.contextMenu.menu.items.firstIndex { $0.title == title })
    }

    // MARK: (a) Every rotate control turns the right way

    func testContextMenuRotateLeftTurnsCounterClockwiseForUprightAndExif8() throws {
        for orientation in [ExifOrientation.up, .left] {
            let url = dir.appendingPathComponent("a-\(orientation.rawValue).jpg")
            XCTAssertTrue(Self.writeQuadrantJPEG(url, orientation: orientation))
            let viewer = viewer([url])
            defer { viewer.close() }
            XCTAssertEqual(shown(viewer), Self.upright)
            viewer.contextMenu.menu.performActionForItem(at: try contextItem(viewer, "Rotate Left"))
            XCTAssertEqual(shown(viewer), Self.turnedLeft,
                           "EXIF \(orientation.rawValue): top-left must go to the bottom-left")
            viewer.contextMenu.menu.performActionForItem(at: try contextItem(viewer, "Rotate Right"))
            viewer.contextMenu.menu.performActionForItem(at: try contextItem(viewer, "Rotate Right"))
            XCTAssertEqual(shown(viewer), Self.turnedRight, "EXIF \(orientation.rawValue)")
            viewer.flushPendingOrientation()
        }
    }

    func testToolbarSegmentAndCommandLTurnTheRightWay() throws {
        let url = dir.appendingPathComponent("t.jpg")
        XCTAssertTrue(Self.writeQuadrantJPEG(url, orientation: .up))
        let viewer = viewer([url])
        defer { viewer.close() }
        let bar = try XCTUnwrap(viewer.toolbarController)
        let group = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.rotate) as? NSToolbarItemGroup)
        group.selectedIndex = 0
        NSApp.sendAction(try XCTUnwrap(group.action), to: group.target, from: group)
        XCTAssertEqual(shown(viewer), Self.turnedLeft, "toolbar Rotate Left")
        group.selectedIndex = 1
        NSApp.sendAction(try XCTUnwrap(group.action), to: group.target, from: group)
        XCTAssertEqual(shown(viewer), Self.upright)

        XCTAssertTrue(viewer.handleKeySnapshot(key("l", 37, .command)))
        XCTAssertEqual(shown(viewer), Self.turnedLeft, "⌘L")
        XCTAssertTrue(viewer.handleKeySnapshot(key("r", 15, .command)))
        XCTAssertTrue(viewer.handleKeySnapshot(key("r", 15, .command)))
        XCTAssertEqual(shown(viewer), Self.turnedRight, "⌘R")
        viewer.flushPendingOrientation()
    }

    /// Upside down: top-left and bottom-right swap, top-right and bottom-left swap.
    static let turned180: Corners = ["yellow", "blue", "green", "red"]

    /// Regression: Rotate RIGHT also turned left on screen.
    /// Every path, both directions, each starting from upright: context
    /// menu items, both toolbar segments, ⌘L / ⌘R, the bare
    /// L / R keys, and Rotate 180° (same picture either way).
    func testEveryRotatePathTurnsBothWaysAndRotate180IsUpsideDown() throws {
        let url = dir.appendingPathComponent("p.jpg")
        XCTAssertTrue(Self.writeQuadrantJPEG(url, orientation: .up))
        let viewer = viewer([url])
        defer { viewer.close() }
        let bar = try XCTUnwrap(viewer.toolbarController)
        let group = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.rotate) as? NSToolbarItemGroup)
        let savedPreset = Prefs.shortcutPreset
        defer { Prefs.shortcutPreset = savedPreset }

        typealias Press = (String, () throws -> Void)
        let menu: (String) -> () throws -> Void = { title in {
            viewer.contextMenu.menu.performActionForItem(at: try self.contextItem(viewer, title))
        } }
        let segment: (Int) -> () throws -> Void = { index in {
            group.selectedIndex = index
            NSApp.sendAction(try XCTUnwrap(group.action), to: group.target, from: group)
        } }
        let keys: (String, UInt16, NSEvent.ModifierFlags) -> () throws -> Void = { chars, code, flags in {
            XCTAssertTrue(viewer.handleKeySnapshot(self.key(chars, code, flags)), "key \(chars)")
        } }
        // (left press, right press) per path.
        let paths: [(String, Press, Press)] = [
            ("context menu", ("Rotate Left", menu("Rotate Left")), ("Rotate Right", menu("Rotate Right"))),
            ("toolbar", ("segment 0", segment(0)), ("segment 1", segment(1))),
            ("command keys", ("⌘L", keys("l", 37, .command)), ("⌘R", keys("r", 15, .command))),
        ]
        func check(_ path: String, _ left: Press, _ right: Press) throws {
            XCTAssertEqual(shown(viewer), Self.upright, "\(path): start")
            try right.1()
            XCTAssertEqual(shown(viewer), Self.turnedRight, "\(path) \(right.0): top-left must go to the top-right")
            try left.1()
            XCTAssertEqual(shown(viewer), Self.upright, "\(path): back")
            try left.1()
            XCTAssertEqual(shown(viewer), Self.turnedLeft, "\(path) \(left.0): top-left must go to the bottom-left")
            try right.1()
            XCTAssertEqual(shown(viewer), Self.upright, "\(path): back")
        }
        for (path, left, right) in paths { try check(path, left, right) }

        // The FastStone preset's bare L / R keys (full-screen habit).
        Prefs.shortcutPreset = .fastStoneCompat
        try check("bare keys", ("L", keys("l", 37, [])), ("R", keys("r", 15, [])))
        Prefs.shortcutPreset = savedPreset

        // Rotate 180° (⇧⌘R, Image menu): upside down; twice = upright.
        try keys("R", 15, [.command, .shift])()
        XCTAssertEqual(shown(viewer), Self.turned180, "⇧⌘R")
        viewer.perform(.rotate180)
        XCTAssertEqual(shown(viewer), Self.upright, "Image ▸ Rotate 180°")
        viewer.flushPendingOrientation()
    }

    // MARK: (b) The written file shows what the view showed

    func testWrittenFileShowsWhatTheViewShowed() async throws {
        for orientation in [ExifOrientation.up, .left] {
            let url = dir.appendingPathComponent("b-\(orientation.rawValue).jpg")
            let other = dir.appendingPathComponent("b-\(orientation.rawValue)-z.jpg")
            XCTAssertTrue(Self.writeQuadrantJPEG(url, orientation: orientation))
            XCTAssertTrue(Self.writeQuadrantJPEG(other, orientation: .up))
            XCTAssertEqual(Self.displayedPicture(url).map(Self.corners), Self.upright, "fixture")
            let viewer = viewer([url, other])
            defer { viewer.close() }
            for ops in [["Rotate Left"], ["Rotate Right"], ["Rotate Right", "Rotate Right"],
                        ["Rotate Right", "Rotate Right", "Rotate Right"], ["Rotate Left", "Rotate Left"]] {
                viewer.markDisplayedForTesting(0)
                let before = try XCTUnwrap(Self.displayedPicture(url).map(Self.corners))
                viewer.imageViewForTesting.image = Self.quadrants()
                XCTAssertEqual(viewer.imageViewForTesting.rotationDegrees, 0)
                for title in ops {
                    viewer.contextMenu.menu.performActionForItem(at: try contextItem(viewer, title))
                }
                let onScreen = Self.screenCorners(viewer.imageViewForTesting.clipSpaceTransform(), texture: before)
                // Away and back: the pending write lands; the new decode
                // carries the file's orientation and the view turn resets.
                viewer.markDisplayedForTesting(1)
                await viewer.waitForOrientationWrites()
                viewer.markDisplayedForTesting(0)
                XCTAssertEqual(viewer.imageViewForTesting.rotationDegrees, 0)
                let reloaded = try XCTUnwrap(Self.displayedPicture(url))
                XCTAssertEqual(Self.corners(of: reloaded), onScreen,
                               "EXIF \(orientation.rawValue) \(ops): the file must show what the view showed")
            }
        }
    }

    // MARK: (c) Any mix of turns and flips matches ExifOrientation

    func testEverySequenceOfUpToThreeOpsMatchesExifOrientation() {
        let url = dir.appendingPathComponent("c.jpg")
        let viewer = viewer([url])
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        let ops: [OrientationOp] = [.rotate(quarters: -1), .rotate(quarters: 1), .rotate(quarters: 2),
                                    .flipHorizontal, .flipVertical]
        var sequences: [[OrientationOp]] = ops.map { [$0] }
        for a in ops { for b in ops { sequences.append([a, b]) } }
        for a in ops { for b in ops { for c in ops { sequences.append([a, b, c]) } } }
        XCTAssertEqual(sequences.count, 155)
        let picture = Self.quadrants()
        for seq in sequences {
            view.resetOrientation()
            for op in seq {
                switch op {
                case .rotate(let q): view.rotateBy(degrees: Double(q) * 90)
                case .flipHorizontal: view.flipHorizontal()
                case .flipVertical: view.flipVertical()
                }
            }
            let net = seq.reduce(ExifOrientation.up) { $0.applying($1) }
            let expected = Self.corners(of: ExifOrientation.apply(net, to: picture))
            let m = MetalImageView.clipSpaceTransform(
                textureWidth: 64, textureHeight: 48, viewSize: CGSize(width: 800, height: 600),
                zoom: 1, pan: .zero, rotationDegrees: view.rotationDegrees,
                flippedH: view.isFlippedHorizontally, flippedV: view.isFlippedVertically)
            XCTAssertEqual(Self.screenCorners(m), expected, "\(seq) → \(net)")
            XCTAssertEqual(view.rotationDegrees, Double(net.components.quarters * 90), "\(seq)")
            XCTAssertEqual(view.isFlippedHorizontally, net.components.mirrored, "\(seq)")
        }
    }

    // MARK: (d) Edit mode ⌘L turns the preview and the saved pixels left

    func testEditModeCommandLTurnsPreviewAndSavedFileCounterClockwise() async throws {
        let url = dir.appendingPathComponent("d.jpg")
        XCTAssertTrue(Self.writeQuadrantJPEG(url, orientation: .up))
        let viewer = viewer([url])
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        // The viewer's own opening decode of the file could land after edit
        // mode began and put the unturned 64 × 48 photo back on the canvas
        // while the loop below waited for the 48 × 64 preview. The
        // `viewer()` helper sets the canvas image by hand, so the canvas
        // cannot tell us when that decode is done. Wait for the real
        // condition: the viewer's opening navigation task has finished.
        let opened = Date().addingTimeInterval(10)
        while !viewer.navCoalescer.isIdle, Date() < opened {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewer.navCoalescer.isIdle, "the opening decode finished")
        XCTAssertFalse(viewer.imageViewForTesting.isCurrentImagePlaceholder)
        content.enterEditMode(image: Self.quadrants(), url: url, landOn: .crop)
        XCTAssertTrue(content.isEditModeActive)
        XCTAssertTrue(viewer.handleKeySnapshot(key("l", 37, .command)))
        let recipe = try XCTUnwrap(content.editModeController.recipe)
        let deadline = Date().addingTimeInterval(3)
        while await recipe.operations.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = await recipe.operations
        XCTAssertEqual(recorded, [.rotate90(quarters: -1)])
        // The preview: a 48 × 64 picture, counter-clockwise, and the view
        // itself is not turned on top of it.
        var preview: CGImage?
        let turned = Date().addingTimeInterval(3)
        while Date() < turned {
            if let image = viewer.imageViewForTesting.image, image.width == 48 { preview = image; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let shownPreview = try XCTUnwrap(preview, "the preview never turned")
        XCTAssertEqual(Self.corners(of: shownPreview), Self.turnedLeft)
        XCTAssertEqual(Self.screenCorners(viewer.imageViewForTesting.clipSpaceTransform()), Self.upright,
                       "edit mode shows the rendered turn, not a view turn")

        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let written = try XCTUnwrap(Self.displayedPicture(url))
        XCTAssertEqual(written.width, 48)
        XCTAssertEqual(Self.corners(of: written), Self.turnedLeft)
    }
}

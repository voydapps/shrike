import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

/// Image > Rotate Right turns the view at once and writes the file later. Edit mode
/// loads the file, so it must start from the file's orientation with no leftover
/// view turn; otherwise the editor's own turn is undone on screen (0.2.25 QA).
@MainActor
final class EditAfterRotateTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-edit-after-rotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ViewerWindow.orientationWriteDelay = .seconds(30)
    }

    override func tearDown() async throws {
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, width: Int = 320, height: Int = 200) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func openViewer() async throws -> ViewerWindow {
        let urls = (0..<2).map { writeJPEG("p\($0).jpg") }
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: 800, height: 600))
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.canPerform(.editImage) && viewer.displayedItem?.listIndex == 0
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        return viewer
    }

    func testEditAfterInPlaceRotateStartsFromTheFileAndTurnsOnScreen() async throws {
        let viewer = try await openViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        viewer.dispatch(.rotateRight)
        XCTAssertEqual(content.imageView.rotationDegrees, 90, "the view turned at once")
        // The file write waits 30 s: Edit Image must write it first.
        viewer.enterEditMode(landOn: .rotate)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        XCTAssertEqual(content.imageView.rotationDegrees, 0, "no leftover view turn under the editor")
        let editor = content.editModeController
        XCTAssertEqual(editor.originalImage?.width, 200, "the editor loaded the rotated file")
        XCTAssertEqual(editor.originalImage?.height, 320)
        editor.appendSnapped90(quarters: -1)
        await editor.settleForTesting()
        let shown = try XCTUnwrap(content.imageView.image)
        XCTAssertEqual(shown.width, 320, "the preview turned left: landscape again")
        XCTAssertEqual(shown.height, 200)
        XCTAssertEqual(content.imageView.rotationDegrees, 0)
    }
}

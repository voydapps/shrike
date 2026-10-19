import XCTest
import os
import ShrikeCore
import ShrikeIO
@testable import ShrikeEdit

final class ContactSheetPreviewTests: XCTestCase {
    func testFirstPageUsesThumbnailPathAndMatchesLayoutBounds() async throws {
        let tmp = EditTempDir("ContactPreview"); defer { tmp.cleanup() }
        let source = try EditFixture.url("small.jpg")
        let thumbnails = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("thumbnails"))
        let groups = Array(repeating: ImageGroup(primary: source), count: 61)
        let options = ContactSheetOptions(title: "Preview", columns: 5)
        let fullDecodes = OSAllocatedUnfairLock(initialState: 0), oldHook = OutputDecoder.decodeHook
        OutputDecoder.decodeHook = { _ in fullDecodes.withLock { $0 += 1 } }
        defer { OutputDecoder.decodeHook = oldHook }
        let image = try await ContactSheetRenderer.firstPagePreview(groups, options: options, thumbnails: thumbnails, maxLongEdge: 320)
        XCTAssertEqual(max(image.width, image.height), 320)
        XCTAssertEqual(ContactSheetLayout(options: options).pageCount(for: groups.count), 3)
        XCTAssertEqual(fullDecodes.withLock { $0 }, 0)
    }
}

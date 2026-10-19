import XCTest
@testable import ShrikeIO

final class FolderDiagnosticsTests: XCTestCase {
    func testUnreadableCandidateIsReportedSeparatelyFromShownPhotos() async throws {
        let tmp = IOTempDir("FolderDiagnostics"); defer { tmp.cleanup() }
        _ = try tmp.file("shown.jpg")
        let unreadable = try tmp.file("denied.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: unreadable.path), "host privileges bypass file permissions")
        let result = try await FolderScanner.imageGroupsWithDiagnostics(in: tmp.url)
        XCTAssertEqual(result.groups.count, 1); XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipped.first?.url.lastPathComponent, "denied.jpg")
        XCTAssertFalse(result.skipped.first?.reason.isEmpty ?? true)
    }
}

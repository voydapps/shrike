import XCTest
@testable import ShrikeIO

final class BackupAvailabilityTests: XCTestCase {
    func testAvailabilityTracksActualOriginalAndBackupPaths() async throws {
        let tmp = IOTempDir("BackupAvailability"); defer { tmp.cleanup() }
        let file = try tmp.file("image.jpg", "original"), date = Date(timeIntervalSince1970: 100)
        let store = BackupStore(root: tmp.url.appendingPathComponent("backups"), now: { date })
        let record = try await store.backup(file, reason: .save)
        var status = await store.availability(for: file)
        XCTAssertTrue(status.canRevert); XCTAssertEqual(status.originalDate, date); XCTAssertEqual(status.latestDate, date)
        let moved = tmp.url.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: file, to: moved)
        status = await store.availability(for: moved)
        XCTAssertFalse(status.canRevert, "Finder-moved paths must not promise untracked recovery")
        status = await store.availability(for: file); XCTAssertFalse(status.canRevert)
        try FileManager.default.moveItem(at: moved, to: file)
        try FileManager.default.removeItem(at: record.backupURL)
        status = await store.availability(for: file)
        XCTAssertFalse(status.canRevert); XCTAssertNil(status.originalDate)
    }
}

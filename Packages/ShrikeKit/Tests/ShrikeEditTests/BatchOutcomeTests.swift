//
//  BatchOutcomeTests.swift
//  ShrikeEditTests
//
//  Audit B-6: "disk full" is decided by error code, never by the word "space" in a message.
//

import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchOutcomeTests: XCTestCase {

    private func isDiskFull(_ error: any Error) -> Bool {
        if case .skipped(.diskFull) = BatchRunner.outcome(for: error) { return true }
        return false
    }

    func testAFolderCalledWorkspaceIsNotAFullDisk() {
        XCTAssertFalse(isDiskFull(BackupError.copyFailed(underlying: "no access to /Users/me/Workspace")))
        XCTAssertFalse(isDiskFull(BackupError.recordWriteFailed(underlying: "space in the name")))
        XCTAssertFalse(isDiskFull(ExportError.backupFailed(underlying: "copyFailed(underlying: \"Workspace\")")))
        XCTAssertFalse(isDiskFull(ExportError.atomicReplaceFailed(underlying: "Not enough space in this word")))
    }

    func testBackupErrorForAFullVolumeIsDiskFull() {
        XCTAssertTrue(isDiskFull(BackupError.insufficientSpace(volumeName: "Macintosh HD")))
        XCTAssertTrue(isDiskFull(ExportError.backupFailed(underlying: "insufficientSpace(volumeName: \"Macintosh HD\")")))
        XCTAssertTrue(isDiskFull(LosslessRotateError.backupFailed(underlying: "insufficientSpace(volumeName: \"Macintosh HD\")")))
    }

    func testErrorCodesAreDiskFullAlsoWhenNested() {
        XCTAssertTrue(isDiskFull(ExportError.diskFull))
        XCTAssertTrue(isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(isDiskFull(nested))
        XCTAssertFalse(isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }
}

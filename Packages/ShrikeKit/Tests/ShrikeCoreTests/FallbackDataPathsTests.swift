import XCTest
@testable import ShrikeCore

final class FallbackDataPathsTests: XCTestCase {
    func testProductionFallbackDirectoryPreservesExistingTemporaryLocation() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let resolved = ShrikeDataPaths.fallbackDirectory(
            isRunningTests: false, testRoot: URL(fileURLWithPath: "/unused-test-root"), temporaryDirectory: temporary)
        XCTAssertEqual(resolved, temporary)
    }

    func testTestFallbackDirectoryUsesGuardedRootEvenWhenTemporaryDirectoryDiffers() {
        let temporary = URL(fileURLWithPath: "/unused-shared-temporary")
        let processRoot = URL(fileURLWithPath: "/unused-process-test-root", isDirectory: true)
        let resolved = ShrikeDataPaths.fallbackDirectory(
            isRunningTests: true, testRoot: processRoot, temporaryDirectory: temporary)
        XCTAssertEqual(resolved, processRoot.appendingPathComponent("Fallback", isDirectory: true))
    }
}

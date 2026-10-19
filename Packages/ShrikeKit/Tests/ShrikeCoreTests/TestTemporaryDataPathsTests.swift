import XCTest
@testable import ShrikeCore

final class TestTemporaryDataPathsTests: XCTestCase {
    private let unusedDefault = URL(fileURLWithPath: "/unused-shared-temporary", isDirectory: true)

    func testExplicitTestOverrideUsesValidatorCanonicalResult() throws {
        let canonical = URL(fileURLWithPath: "/owned/canonical-base", isDirectory: true)
        var requested: URL?
        let result = try ShrikeDataPaths.resolveTestTemporaryBase(
            isRunningTests: true, override: "/owned/base/../private-base", defaultDirectory: unusedDefault
        ) { value in
            requested = value
            return canonical
        }
        XCTAssertEqual(requested?.path, "/owned/private-base")
        XCTAssertEqual(result, canonical)
    }

    func testUnsetTestOverridePreservesDefaultWithoutValidation() throws {
        let result = try ShrikeDataPaths.resolveTestTemporaryBase(
            isRunningTests: true, override: nil, defaultDirectory: unusedDefault
        ) { _ in
            XCTFail("An unset override must preserve existing behavior without validating another location")
            throw ShrikeDataPaths.TestTemporaryDirectoryError.notExistingDirectory
        }
        XCTAssertEqual(result, unusedDefault)
    }

    func testProductionIgnoresEvenInvalidOverridesWithoutValidation() throws {
        for override in ["", "relative", "file:///owned/base", "/owned/base", "/"] {
            let result = try ShrikeDataPaths.resolveTestTemporaryBase(
                isRunningTests: false, override: override, defaultDirectory: unusedDefault
            ) { _ in
                XCTFail("A normal app must ignore test-only configuration")
                throw ShrikeDataPaths.TestTemporaryDirectoryError.notExistingDirectory
            }
            XCTAssertEqual(result, unusedDefault)
        }
    }

    func testInvalidExplicitOverridesFailBeforeDirectoryValidation() {
        for override in ["", "relative/base", "~/private-base", "file:///owned/base", "https://example.test/base",
                         "/", "/owned/..", "//server/share", "/owned/has\0nul"] {
            XCTAssertThrowsError(try ShrikeDataPaths.resolveTestTemporaryBase(
                isRunningTests: true, override: override, defaultDirectory: unusedDefault
            ) { _ in
                XCTFail("Invalid syntax must not reach directory access")
                return self.unusedDefault
            }) { error in
                XCTAssertEqual(error as? ShrikeDataPaths.TestTemporaryDirectoryError, .invalidAbsolutePath)
            }
        }
    }

    func testExplicitValidationFailureDoesNotFallBack() {
        XCTAssertThrowsError(try ShrikeDataPaths.resolveTestTemporaryBase(
            isRunningTests: true, override: "/owned/missing-base", defaultDirectory: unusedDefault
        ) { _ in throw ShrikeDataPaths.TestTemporaryDirectoryError.notExistingDirectory }) { error in
            XCTAssertEqual(error as? ShrikeDataPaths.TestTemporaryDirectoryError, .notExistingDirectory)
        }
    }

    func testExistingDirectoryIsAcceptedAndSymlinkIsCanonicalized() throws {
        let root = try makeOwnedFixture()
        let base = root.appendingPathComponent("private-base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        let resolved = try ShrikeDataPaths.resolveTestTemporaryBase(
            isRunningTests: true, override: alias.path, defaultDirectory: unusedDefault,
            validateDirectory: ShrikeDataPaths.validatedTestTemporaryDirectory)
        XCTAssertEqual(resolved, base.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testMissingAndRegularFileOverridesAreRejected() throws {
        let root = try makeOwnedFixture()
        let file = root.appendingPathComponent("regular-file")
        try Data("owned fixture".utf8).write(to: file)
        for requested in [file, root.appendingPathComponent("does-not-exist", isDirectory: true)] {
            XCTAssertThrowsError(try ShrikeDataPaths.resolveTestTemporaryBase(
                isRunningTests: true, override: requested.path, defaultDirectory: unusedDefault,
                validateDirectory: ShrikeDataPaths.validatedTestTemporaryDirectory)) { error in
                    XCTAssertEqual(error as? ShrikeDataPaths.TestTemporaryDirectoryError, .notExistingDirectory)
                }
        }
    }

    func testDirectoryValidatorRejectsNonFileURLAndRootAlias() throws {
        XCTAssertThrowsError(try ShrikeDataPaths.validatedTestTemporaryDirectory(
            try XCTUnwrap(URL(string: "https://example.test/base"))))
        let root = try makeOwnedFixture()
        let rootAlias = root.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertThrowsError(try ShrikeDataPaths.validatedTestTemporaryDirectory(rootAlias)) { error in
            XCTAssertEqual(error as? ShrikeDataPaths.TestTemporaryDirectoryError, .invalidAbsolutePath)
        }
    }

    func testStaleCleanupOnlyRemovesDeadDirectoryInSelectedBase() throws {
        let root = try makeOwnedFixture()
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let outside = root.appendingPathComponent("sibling", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: selected, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let dead = selected.appendingPathComponent("shrike-tests-900001", isDirectory: true)
        let retainedNames = ["shrike-tests-900002", "shrike-tests-900003", "shrike-tests-0",
                             "shrike-tests--42", "shrike-tests-invalid", "unrelated-folder"]
        for folder in [dead] + retainedNames.map({ selected.appendingPathComponent($0, isDirectory: true) }) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("owned marker".utf8).write(to: folder.appendingPathComponent("marker"))
        }
        let outsideDead = outside.appendingPathComponent("shrike-tests-900001", isDirectory: true)
        try fm.createDirectory(at: outsideDead, withIntermediateDirectories: true)
        let outsideMarker = outsideDead.appendingPathComponent("marker")
        let markerBytes = Data("outside selected base".utf8)
        try markerBytes.write(to: outsideMarker)
        let symlink = selected.appendingPathComponent("shrike-tests-900004")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: outsideDead)
        let regularFile = selected.appendingPathComponent("shrike-tests-900005")
        try markerBytes.write(to: regularFile)
        var checked: [Int32] = []
        ShrikeDataPaths.removeStaleTestRoots(in: selected, currentProcessIdentifier: 900003) { pid in
            checked.append(pid)
            return pid == 900002
        }
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
        for name in retainedNames {
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(name).appendingPathComponent("marker")),
                           Data("owned marker".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: outsideMarker), markerBytes)
        XCTAssertEqual(try Data(contentsOf: regularFile), markerBytes)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: symlink.path), outsideDead.path)
        XCTAssertFalse(checked.contains(0))
        XCTAssertFalse(checked.contains(-42))
        XCTAssertFalse(checked.contains(900003))
    }

    func testActualTestStoresStayBelowSelectedProcessRoot() throws {
        XCTAssertTrue(ShrikeDataPaths.isRunningTests)
        let processRoot = ShrikeDataPaths.testRoot.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(processRoot.lastPathComponent, "shrike-tests-\(ProcessInfo.processInfo.processIdentifier)")
        if let override = ProcessInfo.processInfo.environment[ShrikeDataPaths.testTemporaryDirectoryEnvironmentKey] {
            let expectedBase = try ShrikeDataPaths.validatedTestTemporaryDirectory(
                URL(fileURLWithPath: override, isDirectory: true))
            XCTAssertEqual(processRoot.deletingLastPathComponent(), expectedBase)
        }
        let stores = [ShrikeDataPaths.applicationSupportBase, ShrikeDataPaths.applicationSupport,
                      ShrikeDataPaths.cachesBase, ShrikeDataPaths.caches, ShrikeDataPaths.fallbackDirectory,
                      try XCTUnwrap(ShrikeDefaults.testPreferencesFolder),
                      URL(fileURLWithPath: try XCTUnwrap(ShrikeDefaults.testSuiteName))]
        for store in stores {
            XCTAssertTrue(store.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(processRoot.path + "/"),
                          "Every actual test store must stay below the selected process root")
        }
    }

    private func makeOwnedFixture() throws -> URL {
        let root = ShrikeDataPaths.testRoot.appendingPathComponent("test-temp-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

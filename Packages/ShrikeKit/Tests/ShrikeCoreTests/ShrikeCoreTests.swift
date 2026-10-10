//
//  ShrikeCoreTests.swift
//  ShrikeCoreTests
//
//  Shared helpers + harness smoke test. Per-module tests live in their
//  own files: FileImageSourceTests, ThumbnailCacheTests, DecodeQueueTests,
//  MetadataStoreTests, PrefsTests.
//

import XCTest
@testable import ShrikeCore

final class ShrikeCoreTests: XCTestCase {

    /// Smoke test: the module imports and a basic type can be constructed.
    func testHarness() {
        XCTAssertEqual(ShortcutPreset(rawValue: "macNative"), .macNative)
    }
}

// MARK: - Shared fixture helpers

enum TestFixture {
    /// Locate a bundled fixture by name. Tests refer to `small.jpg` etc.
    static func url(_ name: String) throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        // Fall back to an explicit subdirectory lookup — SwiftPM sometimes
        // nests resources differently depending on platform.
        if let dir = bundle.resourceURL?.appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        {
            return dir.appendingPathComponent(name)
        }
        throw NSError(
            domain: "ShrikeCoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fixture \(name) not found in test bundle"]
        )
    }
}

/// Scoped temporary directory — auto-removed in `tearDown`.
final class TempDir {
    let url: URL

    init(_ label: String = "ShrikeCoreTests") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = root
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

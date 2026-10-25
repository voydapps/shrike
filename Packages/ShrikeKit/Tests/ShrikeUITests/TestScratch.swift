//
//  TestScratch.swift
//  ShrikeUITests
//
//  Rule: a test never makes folders in the shared temp folder
//  (`FileManager.default.temporaryDirectory`, `NSTemporaryDirectory()`).
//  It uses `TestScratch.directory`, a folder in the per-process test root.
//  The folder is removed when the test process exits (late writers such as
//  thumbnail cache jobs can re-create a folder after its test ended, so a
//  per-test tearDown alone is not enough), and a stale root left by a
//  crashed run is removed by the next run. Same helper in each test target
//  (targets can't share a file).
//

import Foundation
import ShrikeCore

enum TestScratch {
    /// `<ShrikeDataPaths.testRoot>/Scratch`, created on first use.
    static let directory: URL = {
        let url = ShrikeDataPaths.testRoot.appendingPathComponent("Scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // One exit hook per process, even though each test target has this file.
        guard getenv("SHRIKE_TEST_SCRATCH_GUARD") == nil else { return url }
        setenv("SHRIKE_TEST_SCRATCH_GUARD", "1", 1)
        TestScratchExit.snapshot.withLock { $0 = sharedTempNames() }
        atexit {
            try? FileManager.default.removeItem(at: TestScratch.directory)
            // Guard: report new top-level entries in the shared temp folder.
            let own = ShrikeDataPaths.testRoot.lastPathComponent
            let before = TestScratchExit.snapshot.withLock { $0 }
            let added = TestScratch.sharedTempNames().subtracting(before).filter { $0 != own }
            let ours = added.filter { name in
                ["shrike", "thumb", "contact-sheet", "meta-", "Shrike"].contains { name.hasPrefix($0) }
            }
            if !ours.isEmpty {
                print("TestScratch: LEAK, a test made \(ours.count) entries in the shared temp folder: \(ours.sorted().prefix(10))")
            }
        }
        return url
    }()

    fileprivate static func sharedTempNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
    }
}

private enum TestScratchExit {
    static let snapshot = TestScratchBox<Set<String>>([])
}

private final class TestScratchBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

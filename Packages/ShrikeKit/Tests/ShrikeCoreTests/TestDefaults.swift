//
//  TestDefaults.swift
//  ShrikeCoreTests
//
//  Rule: a test that needs its own UserDefaults calls `makeTestDefaults()`,
//  never `UserDefaults(suiteName:)`. The suite lives in the per-process
//  temp root (never ~/Library/Preferences) and is removed when the test
//  ends. Same helper in each test target (targets can't share a file).
//

import XCTest
import ShrikeCore

extension XCTestCase {
    /// A new, empty UserDefaults suite for this test only. Its domain and
    /// plist are removed by a teardown block when the test ends.
    func makeTestDefaults(_ label: String? = nil) -> UserDefaults {
        let suite = ShrikeDefaults.makeScratchSuite(label: label ?? String(describing: type(of: self)))
        let name = suite.name
        addTeardownBlock { ShrikeDefaults.removeScratchSuite(named: name) }
        return suite.defaults
    }
}

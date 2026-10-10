//
//  FolderTreeLookupTests.swift
//  ShrikeUITests
//
//  Regression: selecting a folder in the browser sidebar used a
//  depth-first search that listed every folder under every root on the
//  main thread (all of ~/Library first — 60 s+ beachball — plus Desktop /
//  Documents / Downloads, which fired privacy prompts). `node(for:)` must
//  list only the target's ancestor chain.
//

import XCTest
import Foundation
@testable import ShrikeUI

@MainActor
final class FolderTreeLookupTests: XCTestCase {

    private var tempRoot: URL!
    private var listed: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shrike-tree-lookup-\(UUID().uuidString)")
        // A big sibling branch that sorts BEFORE the target branch — the
        // old search listed all of it first.
        for i in 0..<30 {
            try fm.createDirectory(
                at: tempRoot.appendingPathComponent("aaa-big/sub\(i)/leaf"),
                withIntermediateDirectories: true
            )
        }
        try fm.createDirectory(
            at: tempRoot.appendingPathComponent("photos/2026/trip"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: tempRoot.appendingPathComponent("zzz-other/deep"),
            withIntermediateDirectories: true
        )
        listed = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    /// Data source whose sidebar holds only the given folders (no real
    /// Home / Desktop / … roots, so the test never touches them).
    private func makeSource(roots: [URL]) -> FolderTreeDataSource {
        let source = FolderTreeDataSource()
        let section = FolderTreeNode(url: nil, title: "Locations", section: .locations)
        section.childrenLoaded = true
        for url in roots {
            let node = FolderTreeNode(url: url, title: url.lastPathComponent)
            node.parent = section
            section.children.append(node)
        }
        source.roots = [section]
        source.didListFolder = { [unowned self] url in
            self.listed.append(url.standardizedFileURL.path)
        }
        return source
    }

    private func rel(_ path: String) -> String {
        tempRoot.appendingPathComponent(path).standardizedFileURL.path
    }

    func testLookupListsOnlyTheAncestorChain() async {
        let source = makeSource(roots: [tempRoot])
        let target = tempRoot.appendingPathComponent("photos/2026/trip")

        let node = await source.node(for: target)

        XCTAssertEqual(node?.url?.lastPathComponent, "trip")
        XCTAssertEqual(listed, [tempRoot.standardizedFileURL.path, rel("photos"), rel("photos/2026")],
                       "only the root and the target's ancestors may be listed")
        XCTAssertFalse(listed.contains { $0.contains("aaa-big") || $0.contains("zzz-other") })
    }

    func testLookupSelectingTheRootItselfListsNothing() async {
        let source = makeSource(roots: [tempRoot])
        let awaited1 = await source.node(for: tempRoot)?.url?.standardizedFileURL
        XCTAssertEqual(awaited1, tempRoot.standardizedFileURL)
        XCTAssertTrue(listed.isEmpty)
    }

    func testLookupPrefersTheDeepestRoot() async {
        // Like ~/Pictures being both under Home and its own sidebar root.
        let photos = tempRoot.appendingPathComponent("photos")
        let source = makeSource(roots: [tempRoot, photos])

        let node = await source.node(for: tempRoot.appendingPathComponent("photos/2026"))

        XCTAssertEqual(node?.url?.lastPathComponent, "2026")
        XCTAssertEqual(node?.parent?.url?.standardizedFileURL, photos.standardizedFileURL)
        XCTAssertEqual(listed, [rel("photos")], "must start from the deepest matching root")
    }

    func testLookupOutsideEveryRootListsNothingAndReturnsNil() async {
        let source = makeSource(roots: [tempRoot.appendingPathComponent("zzz-other")])
        let awaited2 = await source.node(for: tempRoot.appendingPathComponent("photos/2026"))
        XCTAssertNil(awaited2)
        XCTAssertTrue(listed.isEmpty)
    }

    func testLookupDoesNotMatchASiblingWithACommonNamePrefix() async {
        // "/x/photos-archive" must not count as inside root "/x/photos".
        try? FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("photos-archive/a"),
            withIntermediateDirectories: true
        )
        let source = makeSource(roots: [tempRoot.appendingPathComponent("photos")])
        let awaited3 = await source.node(for: tempRoot.appendingPathComponent("photos-archive/a"))
        XCTAssertNil(awaited3)
        XCTAssertTrue(listed.isEmpty)
    }

    func testLookupOfMissingFolderStopsAtTheFirstMissingComponent() async {
        let source = makeSource(roots: [tempRoot])
        let awaited4 = await source.node(for: tempRoot.appendingPathComponent("photos/nope/deeper"))
        XCTAssertNil(awaited4)
        XCTAssertEqual(listed, [tempRoot.standardizedFileURL.path, rel("photos")])
    }

    func testLookupReusesAlreadyLoadedChildren() async {
        let source = makeSource(roots: [tempRoot])
        _ = await source.node(for: tempRoot.appendingPathComponent("photos/2026/trip"))
        listed = []
        let awaited5 = await source.node(for: tempRoot.appendingPathComponent("photos/2026"))
        XCTAssertNotNil(awaited5)
        XCTAssertTrue(listed.isEmpty, "a second lookup on the same chain hits the cache")
    }
}

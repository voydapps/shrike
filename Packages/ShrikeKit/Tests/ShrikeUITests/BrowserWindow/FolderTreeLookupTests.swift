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
        tempRoot = TestScratch.directory
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

    /// A part that its parent's listing does not show gets a 50 % path row
    /// (spec 22-sidebar §4.4 rule 5); the walk continues below it.
    func testLookupOfMissingFolderInsertsPathRows() async throws {
        let source = makeSource(roots: [tempRoot])
        let node = await source.node(for: tempRoot.appendingPathComponent("photos/nope/deeper"))
        let row = try XCTUnwrap(node)
        XCTAssertEqual(row.title, "deeper")
        XCTAssertTrue(row.isPathRow)
        XCTAssertTrue(row.parent?.isPathRow == true)
        XCTAssertEqual(row.parent?.title, "nope")
        XCTAssertEqual(listed.prefix(2), [tempRoot.standardizedFileURL.path, rel("photos")])
        // The path row is a child of the folder that did not list it.
        XCTAssertTrue(row.parent?.parent?.children.contains { $0.title == "nope" } == true)
    }

    /// A folder hidden while "Show hidden files" is off is found as a path row.
    func testLookupOfHiddenFolderIsAPathRowThenARealRow() async throws {
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(".secret/inner"), withIntermediateDirectories: true)
        let source = makeSource(roots: [tempRoot])
        source.showHiddenFiles = false
        let hiddenOff = await source.node(for: tempRoot.appendingPathComponent(".secret/inner"))
        XCTAssertEqual(hiddenOff?.parent?.isPathRow, true)
        XCTAssertEqual(hiddenOff?.parent?.title, ".secret")
        XCTAssertEqual(hiddenOff?.parent?.isDimmed, true)
        XCTAssertEqual(hiddenOff?.title, "inner")
        XCTAssertEqual(hiddenOff?.isPathRow, false, "inner is listed by its (path-row) parent")
        // With hidden files on, the same folder is a normal hidden row.
        let other = makeSource(roots: [tempRoot])
        other.showHiddenFiles = true
        let hiddenOn = await other.node(for: tempRoot.appendingPathComponent(".secret/inner"))
        XCTAssertEqual(hiddenOn?.parent?.isPathRow, false)
        XCTAssertEqual(hiddenOn?.parent?.isHidden, true)
    }

    /// A folder outside Home resolves under the "/" root, and /private/tmp
    /// (which Foundation writes as /tmp) is read as the `private` folder.
    func testLookupOutsideHomeResolvesUnderTheStartupDisk() async throws {
        let source = FolderTreeDataSource()
        let startup = SidebarVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", kind: .internal, isEjectable: false)
        source.rebuildRoots(favorites: [], volumes: [startup])
        XCTAssertEqual(FolderTreeDataSource.lookupComponents(URL(fileURLWithPath: "/private/tmp/x")),
                       ["/", "private", "tmp", "x"])
        // Lister fake: a tiny "/" so nothing real is read.
        source.lister = { folder, _ in
            switch folder.standardizedFileURL.path {
            case "/": return [URL(fileURLWithPath: "/private", isDirectory: true), URL(fileURLWithPath: "/Users", isDirectory: true)]
            case "/private": return [URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            case "/tmp": return [URL(fileURLWithPath: "/private/tmp/x", isDirectory: true)]
            default: return []
            }
        }
        let node = await source.node(for: URL(fileURLWithPath: "/private/tmp/x"))
        XCTAssertEqual(node?.title, "x")
        var chain: [String] = []
        var cursor = node
        while let item = cursor { chain.append(item.title); cursor = item.parent }
        XCTAssertEqual(chain, ["x", "tmp", "private", "Macintosh HD", "Locations"])
        XCTAssertEqual(node?.isPathRow, false)
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

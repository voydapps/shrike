//
//  GroupListScaleTests.swift
//  ShrikeUITests
//
//  A viewer list answers lookups from a hash table (audit MP-01): a watcher
//  batch over a big folder no longer costs n² path resolutions on main.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class GroupListScaleTests: XCTestCase {

    private func name(_ i: Int) -> URL {
        URL(fileURLWithPath: "/tmp/shrike-scale/IMG_\(String(format: "%05d", i)).jpg")
    }

    private func makeList(_ n: Int) -> GroupList {
        GroupList((0..<n).map { ImageGroup(primary: name($0)) })
    }

    private func best(runs: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            let d = ContinuousClock.now - start
            best = min(best, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        return best
    }

    /// What `insertAddedFiles` does when a watcher batch arrives: one
    /// lookup per scanned file, plus the new one. The old code needed
    /// about 28 s for 2000 items.
    func testTwoThousandItemListAnswersAScanPassInUnderFiftyMilliseconds() {
        let list = makeList(2000)
        let scanned = (0...2000).map(name)
        let seconds = best {
            var found = 0
            for url in scanned where list.index(of: url) != nil { found += 1 }
            XCTAssertEqual(found, 2000)
        }
        XCTAssertLessThan(seconds, 0.05, "scan pass took \(seconds) s")
    }

    func testFiveThousandItemListScanPass() {
        let list = makeList(5000)
        let scanned = (0...5000).map(name)
        let seconds = best {
            var found = 0
            for url in scanned where list.index(of: url) != nil { found += 1 }
            XCTAssertEqual(found, 5000)
        }
        XCTAssertLessThan(seconds, 0.15, "scan pass took \(seconds) s")
    }

    func testLookupFollowsReplaceRemoveAndInsert() {
        var list = makeList(10)
        let a = name(4)
        XCTAssertEqual(list.index(of: a), 4)
        let renamed = URL(fileURLWithPath: "/tmp/shrike-scale/renamed.jpg")
        list.replace(at: 4, with: ImageGroup(primary: renamed))
        XCTAssertNil(list.index(of: a))
        XCTAssertEqual(list.index(of: renamed), 4)
        list.remove(primaries: [name(1)])
        XCTAssertEqual(list.index(of: renamed), 3)
        list.insert([RemovedGroup(index: 0, group: ImageGroup(primary: a))])
        XCTAssertEqual(list.index(of: a), 0)
        XCTAssertEqual(list.index(of: renamed), 4)
        // A copy keeps its own table.
        var copy = list
        copy.replace(at: 0, with: ImageGroup(primary: URL(fileURLWithPath: "/tmp/shrike-scale/other.jpg")))
        XCTAssertEqual(list.index(of: a), 0)
        XCTAssertNil(copy.index(of: a))
    }

    /// End to end: a viewer on a 2000-file folder gets one new file. The
    /// main thread must not stall (old code: ~28 s of path resolution).
    func testViewerWithTwoThousandFilesInsertsOneAddedFileWithoutStalling() async throws {
        let root = TestScratch.directory
            .appendingPathComponent("shrike-scale-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        for i in 0..<2000 where i != 1000 {
            let url = dir.appendingPathComponent("IMG_\(String(format: "%05d", i)).jpg")
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            urls.append(url)
        }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        defer { viewer.close() }
        let added = dir.appendingPathComponent("IMG_01000.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: added)
        viewer.handleFolderChange(FolderChange(added: [added]), in: dir)
        var longestGap = 0.0
        var last = ContinuousClock.now
        let deadline = Date().addingTimeInterval(10)
        while viewer.groups.count < 2000, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            let d = now - last
            longestGap = max(longestGap, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            last = now
        }
        XCTAssertEqual(viewer.groups.count, 2000)
        XCTAssertEqual(viewer.groups[1000].primary.lastPathComponent, "IMG_01000.jpg")
        XCTAssertLessThan(longestGap, 0.5, "main thread stalled \(longestGap) s")
    }
}

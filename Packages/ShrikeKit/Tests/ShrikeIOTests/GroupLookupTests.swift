//
//  GroupLookupTests.swift
//  ShrikeIOTests
//
//  The hash lookup that replaced per-URL list scans (audit MP-01 / MP-02):
//  same answers as `FolderScanner.index(of:in:)`, and fast at scale.
//

import XCTest
@testable import ShrikeCore
@testable import ShrikeIO

final class GroupLookupTests: XCTestCase {

    private func groups(_ n: Int, in dir: String = "/tmp/shrike-lookup-fake") -> [ImageGroup] {
        (0..<n).map { i in
            let stem = "\(dir)/IMG_\(String(format: "%05d", i))"
            let primary = URL(fileURLWithPath: stem + ".jpg")
            if i % 5 == 0 {
                return ImageGroup(primary: primary,
                                  companions: [.init(url: URL(fileURLWithPath: stem + ".NEF"), kind: .raw)])
            }
            return ImageGroup(primary: primary)
        }
    }

    func testFindsPrimaryAndCompanionAndMissesUnknown() {
        let list = groups(50)
        let lookup = GroupLookup(list)
        XCTAssertEqual(lookup.index(of: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/IMG_00007.jpg"), in: list), 7)
        XCTAssertEqual(lookup.index(of: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/IMG_00010.NEF"), in: list), 10)
        XCTAssertNil(lookup.index(of: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/IMG_99999.jpg"), in: list))
        XCTAssertEqual(lookup.index(of: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/./IMG_00003.jpg"), in: list), 3)
    }

    func testMatchesThroughSymlinkedParent() throws {
        let tmp = IOTempDir("lookup-symlink")
        defer { tmp.cleanup() }
        let real = try tmp.dir("real")
        let photo = try tmp.file("a.jpg", in: "real")
        let link = tmp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let list = [ImageGroup(primary: photo)]
        let lookup = GroupLookup(list)
        XCTAssertEqual(lookup.index(of: link.appendingPathComponent("a.jpg"), in: list), 0)
    }

    func testCaseOnlyMatchNeedsTheFallbackFlag() {
        let list = [ImageGroup(primary: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/Photo.JPG"))]
        let lookup = GroupLookup(list)
        let other = URL(fileURLWithPath: "/tmp/shrike-lookup-fake/photo.jpg")
        XCTAssertNil(lookup.index(of: other, in: list))
        XCTAssertEqual(lookup.index(of: other, in: list, caseInsensitiveFallback: true), 0)
    }

    func testReplaceAtKeepsLookupCurrent() {
        var list = groups(10)
        var lookup = GroupLookup(list)
        let renamed = ImageGroup(primary: URL(fileURLWithPath: "/tmp/shrike-lookup-fake/renamed.jpg"))
        let old = list[3]
        list[3] = renamed
        lookup.replace(at: 3, old: old, new: renamed)
        XCTAssertEqual(lookup.index(of: renamed.primary, in: list), 3)
        XCTAssertNil(lookup.index(of: old.primary, in: list))
    }

    /// 5000 groups, 5000 selected URLs: one table, one pass. The old
    /// per-URL scan took 5.3 s here (audit MP-02).
    func testFiveThousandLookupsAreFast() {
        let list = groups(5000)
        let urls = list.map(\.primary)
        var best = Double.infinity
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let lookup = GroupLookup(list)
            var hits = 0
            for url in urls where lookup.index(of: url, in: list, caseInsensitiveFallback: true) != nil { hits += 1 }
            XCTAssertEqual(hits, 5000)
            let d = ContinuousClock.now - start
            best = min(best, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        XCTAssertLessThan(best, 0.5, "5000 lookups took \(best) s")
    }
}

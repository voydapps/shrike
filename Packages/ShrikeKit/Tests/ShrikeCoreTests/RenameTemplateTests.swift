//
//  RenameTemplateTests.swift
//  ShrikeCoreTests
//

import XCTest
@testable import ShrikeCore

final class RenameTemplateTests: XCTestCase {

    private func info(taken: String? = "2026:09:25 14:02:31", lens: String? = nil) -> PhotoInfo {
        var i = PhotoInfo()
        i.dateTaken = taken.flatMap { PhotoInfo.exifDate($0, offsetSeconds: nil) }
        i.lens = lens
        i.make = "FUJIFILM"; i.model = "X-T5"
        i.iso = 200; i.aperture = 2.8; i.shutter = 0.004; i.focal = 23
        return i
    }

    func testEveryListedTokenParses() throws {
        for t in RenameTemplate.tokens {
            XCTAssertNoThrow(try RenameTemplate(parsing: "x_\(t)"), t)
        }
    }

    func testParseErrors() {
        XCTAssertThrowsError(try RenameTemplate(parsing: "a_{foo}_b")) { e in
            XCTAssertEqual(e as? RenameTemplateError, .unknownToken("foo", 2..<7))
        }
        XCTAssertThrowsError(try RenameTemplate(parsing: "a_{name")) { e in
            XCTAssertEqual(e as? RenameTemplateError, .unclosedBrace(at: 2))
        }
        XCTAssertThrowsError(try RenameTemplate(parsing: "{counter:ab}")) { e in
            XCTAssertEqual(e as? RenameTemplateError,
                           .invalidArgument(token: "counter", argument: "ab", 0..<12))
        }
        XCTAssertThrowsError(try RenameTemplate(parsing: "{date:qqq}"))
        XCTAssertThrowsError(try RenameTemplate(parsing: "")) { e in
            XCTAssertEqual(e as? RenameTemplateError, .empty)
        }
    }

    /// A missing value collapses.
    func testMissingValueCollapses() throws {
        let t = try RenameTemplate(parsing: "{yyyy-MM-dd}_{lens}_{counter:00}")
        let stem = t.render(info: info(), originalStem: "DSC_0001", counter: 1, case: .keep)
        XCTAssertEqual(stem, "2026-09-25_01")
    }

    func testTokens() throws {
        let t = try RenameTemplate(parsing: "{camera} {lens} ISO{iso} f{aperture} {shutter}s {focal}mm r{rating} {HH-mm-ss} {ext}")
        let s = t.render(info: info(lens: "XF23mmF1.4 R"), originalStem: "x", counter: 1,
                         case: .keep, rating: 4, fileExtension: "RAF")
        XCTAssertEqual(s, "FUJIFILM X-T5 XF23mmF1.4 R ISO200 f2.8 1-250s 23mm r4 14-02-31 RAF")
    }

    func testSlashColonAndEdges() throws {
        let t = try RenameTemplate(parsing: "__a/b:c  -- {lens}_")
        XCTAssertEqual(t.render(info: nil, originalStem: "", counter: 1, case: .keep), "a-b-c")
        let braces = try RenameTemplate(parsing: "{{x}}_{name}")
        XCTAssertEqual(braces.render(info: nil, originalStem: "n", counter: 1, case: .keep), "{x}_n")
    }

    func testCounterPaddingAndStart() throws {
        let t = try RenameTemplate(parsing: "img_{counter:0000}", counterStart: 7)
        let urls = (1...3).map { URL(fileURLWithPath: "/nonexistent/shrike/f\($0).jpg") }
        let names = t.plan(for: urls, fileExists: { _ in false }).map(\.newName)
        XCTAssertEqual(names, ["img_0007.jpg", "img_0008.jpg", "img_0009.jpg"])
        let w = try RenameTemplate(parsing: "{counter:3}")
        XCTAssertEqual(w.render(info: nil, originalStem: "", counter: 5, case: .keep), "005")
        XCTAssertEqual(w.render(info: nil, originalStem: "", counter: 12345, case: .keep), "12345")
    }

    func testCaseChangesStemOnly_extensionKept() throws {
        let t = try RenameTemplate(parsing: "{name}_Trip", nameCase: .lower)
        let rows = t.plan(for: [URL(fileURLWithPath: "/nonexistent/shrike/IMG_0042.JPG")],
                          fileExists: { _ in false })
        XCTAssertEqual(rows.map(\.newName), ["img_0042_trip.JPG"])
        let u = try RenameTemplate(parsing: "{name:upper}-x")
        XCTAssertEqual(u.render(info: nil, originalStem: "abc", counter: 1, case: .keep), "ABC-x")
        XCTAssertEqual(u.render(info: nil, originalStem: "abc", counter: 1, case: .title), "Abc-X")
    }

    func testDateFallsBackToFileDate_andFiledateFormat() throws {
        let t = try RenameTemplate(parsing: "{date:yyyyMMdd}_{filedate:yyyy}")
        let fileDate = PhotoInfo.exifDate("2020:01:02 03:04:05", offsetSeconds: nil)
        XCTAssertEqual(t.render(info: info(taken: nil), originalStem: "x", counter: 1, case: .keep,
                                fileDate: fileDate), "20200102_2020")
        XCTAssertEqual(t.render(info: info(), originalStem: "x", counter: 1, case: .keep,
                                fileDate: fileDate), "20260925_2020")
    }

    func testTakenDateUsesRecordedOffset() throws {
        var i = PhotoInfo()
        i.dateTakenOffsetSeconds = -5 * 3600
        i.dateTaken = PhotoInfo.exifDate("2026:09:25 23:30:00", offsetSeconds: -5 * 3600)
        let t = try RenameTemplate(parsing: "{yyyy-MM-dd}_{HH-mm-ss}")
        XCTAssertEqual(t.render(info: i, originalStem: "", counter: 1, case: .keep),
                       "2026-09-25_23-30-00", "wall clock where the photo was taken")
    }

    func testPlanFlagsCollisions() throws {
        let tmp = TempDir("rename-plan")
        defer { tmp.cleanup() }
        func make(_ n: String) throws -> URL {
            let u = tmp.url.appendingPathComponent(n)
            try Data("x".utf8).write(to: u)
            return u
        }
        let a = try make("a.jpg"), b = try make("b.jpg"), c = try make("c.jpg")
        _ = try make("taken.jpg")                               // not in the batch

        // Same name for everyone → first wins, the rest clash.
        let same = try RenameTemplate(parsing: "same")
        let r1 = same.plan(for: [a, b])
        XCTAssertEqual(r1.map(\.issue), [nil, .duplicateInBatch])

        // Clash with a file outside the batch.
        let taken = try RenameTemplate(parsing: "taken")
        XCTAssertEqual(taken.plan(for: [a]).first?.issue, .existsOnDisk)

        // Rotating names inside the batch (a→b, b→c) is fine: b and c are
        // being renamed themselves.
        let rot = try RenameTemplate(parsing: "{counter}")
        let r2 = rot.plan(for: [a, b])            // → 1.jpg, 2.jpg
        XCTAssertEqual(r2.map(\.issue), [nil, nil])
        let shift = try RenameTemplate(parsing: "{name}")
        let r3 = shift.plan(for: [a, b, c])
        XCTAssertEqual(r3.map(\.isUnchanged), [true, true, true])
        XCTAssertEqual(r3.map(\.issue), [nil, nil, nil])

        // An unchanged file keeps its slot even when it comes later.
        let pick = try RenameTemplate(parsing: "b")
        let r4 = pick.plan(for: [a, b])
        XCTAssertEqual(r4.map(\.issue), [.duplicateInBatch, nil])
        XCTAssertEqual(r4.map(\.isUnchanged), [false, true])

        // Empty render.
        let empty = try RenameTemplate(parsing: "{lens}")
        XCTAssertEqual(empty.plan(for: [a], info: { _ in nil }).first?.issue, .emptyName)

        let preview = shift.preview(for: [a])
        XCTAssertEqual(preview.first?.1, "a.jpg")
    }

    func testPlanCollisionIgnoresCaseOnCaseInsensitiveVolume() throws {
        let tmp = TempDir("rename-case")
        defer { tmp.cleanup() }
        try XCTSkipUnless(CanonicalPath.isCaseInsensitive(directory: tmp.url.path))
        let a = tmp.url.appendingPathComponent("one.jpg")
        let b = tmp.url.appendingPathComponent("two.jpg")
        try Data().write(to: a); try Data().write(to: b)
        try Data().write(to: tmp.url.appendingPathComponent("Other.jpg"))
        let t = try RenameTemplate(parsing: "OTHER")
        XCTAssertEqual(t.plan(for: [a]).first?.issue, .existsOnDisk)
        let mixed = try RenameTemplate(parsing: "{counter}x", counterStart: 1)
        let rows = mixed.plan(for: [a, b], info: { _ in nil })
        XCTAssertEqual(rows.map(\.newName), ["1x.jpg", "2x.jpg"])
    }

    func testLongNamesFit255Bytes() throws {
        let t = try RenameTemplate(parsing: String(repeating: "é", count: 300))
        let rows = t.plan(for: [URL(fileURLWithPath: "/nonexistent/shrike/a.jpeg")], fileExists: { _ in false })
        XCTAssertLessThanOrEqual(rows[0].newName.utf8.count, 255)
        XCTAssertTrue(rows[0].newName.hasSuffix(".jpeg"))
    }
}

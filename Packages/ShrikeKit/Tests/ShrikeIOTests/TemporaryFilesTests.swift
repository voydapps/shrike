//
//  TemporaryFilesTests.swift
//  ShrikeIOTests
//
//  Audit B-7: stale temp COPIES are swept; temp names that hold the ONLY copy of a photo are
//  never deleted and can be put back through the journal.
//

import XCTest
import ShrikeCore
@testable import ShrikeIO

final class TemporaryFilesTests: XCTestCase {

    var tmp: IOTempDir!
    var launchProbe = Date()

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("TempFiles")
        launchProbe = Date()
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: url.path)
    }

    // MARK: Sweeper

    func testSweepRemovesOldCopyTempsButNeverAnOnlyCopyOrAPhoto() throws {
        let folder = try tmp.dir("cam")
        let id = UUID().uuidString
        let oldCopies = [".IMG_1.jpg.shrikerotate.\(id)", ".IMG_1.jpg.shrikerestore.\(id)",
                         ".IMG_1.jpg.shriketransfer.\(id)", ".IMG_1.shrikeedit.\(id).jpg.tmp"]
        let keepers = [".shrike-rename-\(id)-IMG_2.jpg",            // the only copy mid-rename
                       "IMG_3 shrike-tmp-ABCD1234.jpg",              // Batch's moved-aside photo
                       ".notes.shrikerotate.not-a-uuid",             // looks similar, is not ours
                       "IMG_1.jpg", ".hidden-photo.jpg"]
        let fresh = ".IMG_9.jpg.shriketransfer.\(UUID().uuidString)"   // young: kept by testACopyThat… below
        for name in oldCopies + keepers + [fresh] {
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            if name != fresh { try age(url, hours: 2) }
        }
        // setAttributes also moves the attribute-change date to now, so "later" is passed in.
        TemporaryFileSweeper.sweep(in: folder, now: Date().addingTimeInterval(3 * 3600))
        for name in oldCopies { XCTAssertFalse(exists(folder.appendingPathComponent(name)), "\(name) should be swept") }
        for name in keepers { XCTAssertTrue(exists(folder.appendingPathComponent(name)), "\(name) must stay") }
    }

    /// Review F8: a copy keeps its source's old date, but it was made just now.
    func testACopyThatKeptAnOldSourceDateIsNotSweptAtBirth() throws {
        let folder = try tmp.dir("cam2")
        let temp = folder.appendingPathComponent(".IMG_1.jpg.shriketransfer.\(UUID().uuidString)")
        try Data([1]).write(to: temp)
        try age(temp, hours: 48)                              // like copyItem: the source's old date
        TemporaryFileSweeper.sweep(in: folder)                 // real "now"
        XCTAssertTrue(exists(temp), "its attribute-change date is fresh, so it may belong to work in progress")
    }

    func testTheFolderIsSweptOnceHoweverItsPathIsSpelled() throws {
        let folder = try tmp.dir("cam3")
        let id = UUID().uuidString
        let temp = folder.appendingPathComponent(".a.jpg.shrikerotate.\(id)")
        try Data([1]).write(to: temp)
        TemporaryFileSweeper.sweep(in: folder, now: Date().addingTimeInterval(7200))        // sweeps (and removes) it
        XCTAssertFalse(exists(temp))
        try Data([1]).write(to: temp)
        let spelled = URL(fileURLWithPath: folder.path + "/./")
        TemporaryFileSweeper.sweep(in: spelled, now: Date().addingTimeInterval(7200))
        XCTAssertTrue(exists(temp), "the same folder under another spelling was not swept again")
    }

    func testNameRules() {
        let id = UUID().uuidString
        XCTAssertTrue(TemporaryFileSweeper.isCopyTemp(".a.b.jpg.shrikerotate.\(id)"))
        XCTAssertFalse(TemporaryFileSweeper.isCopyTemp("a.jpg.shrikerotate.\(id)"), "must be hidden")
        XCTAssertFalse(TemporaryFileSweeper.isCopyTemp(".shrike-rename-\(id)-a.jpg"))
    }

    // MARK: Journal

    private func journal() throws -> RenameJournal { RenameJournal(directory: try tmp.dir("_journal")) }

    func testBeginAndEndLeaveNothingPending() throws {
        let j = try journal()
        let id = j.begin(moves: [(tmp.url.appendingPathComponent("a.jpg"), tmp.url.appendingPathComponent("tmp-a.jpg"))])
        XCTAssertEqual(j.pending().count, 1)
        j.end(id)
        XCTAssertTrue(j.pending().isEmpty)
    }

    func testRecoverPutsTheOldNameBackWhenItIsFree() async throws {
        let j = try journal()
        let original = tmp.url.appendingPathComponent("IMG.jpg")
        let temp = try tmp.file(".shrike-rename-X-IMG.jpg", "photo")   // the crash left the photo here
        _ = j.begin(moves: [(original, temp)])
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertEqual(report.restored, [original])
        XCTAssertTrue(report.needsAttention.isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "photo")
        XCTAssertFalse(exists(temp))
        XCTAssertTrue(j.pending().isEmpty, "the entry is done")
    }

    func testRecoverNeverOverwritesAndReportsAPhotoWhoseNameIsTaken() async throws {
        let j = try journal()
        let original = try tmp.file("IMG.jpg", "someone else now")
        let temp = try tmp.file("IMG shrike-tmp-ABCD1234.jpg", "my photo")
        let id = try XCTUnwrap(j.begin(moves: [(original, temp)]))
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertEqual(report.needsAttention.map(\.temporary), [temp])
        XCTAssertEqual(report.needsAttention.map(\.original), [original])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "someone else now")
        XCTAssertEqual(try String(contentsOf: temp, encoding: .utf8), "my photo", "nothing was deleted")
        XCTAssertEqual(j.pending().count, 1, "reported again next launch until solved")
        j.dismiss(id)
        XCTAssertTrue(j.pending().isEmpty)
    }

    func testRecoverDropsAnEntryWhoseTempNameIsGone() async throws {
        let j = try journal()
        _ = j.begin(moves: [(tmp.url.appendingPathComponent("a.jpg"), tmp.url.appendingPathComponent("gone.jpg"))])
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(report.restored.isEmpty && report.needsAttention.isEmpty)
        XCTAssertTrue(j.pending().isEmpty, "the rename finished or was rolled back")
    }

    // MARK: FileOps uses it

    func testCaseOnlyRenameLeavesNoJournalEntryBehind() async throws {
        let before = RenameJournal.shared.pending().count
        let file = try tmp.file("img.jpg", "x", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        _ = try await ops.rename(ImageGroup(primary: file), toStem: "IMG")
        XCTAssertEqual(RenameJournal.shared.pending().count, before)
        XCTAssertEqual(FileOps.renamedURLs(of: ImageGroup(primary: file), toStem: "IMG").map(\.lastPathComponent), ["IMG.jpg"])
    }

    // MARK: Review F4, F5

    func testAnEntryWhoseFolderIsMissingIsKeptForTheNextLaunch() async throws {
        let j = try journal()
        let gone = URL(fileURLWithPath: "/Volumes/NotMounted-\(UUID().uuidString)/cam")
        _ = j.begin(moves: [(gone.appendingPathComponent("a.jpg"), gone.appendingPathComponent(".shrike-rename-X-a.jpg"))])
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(report.restored.isEmpty && report.needsAttention.isEmpty)
        XCTAssertEqual(j.pending().count, 1, "an unplugged disk may hold a stranded photo")
    }

    func testARenameRunningNowIsNotUndoneFromUnderItself() async throws {
        let j = try journal()
        let original = tmp.url.appendingPathComponent("IMG.jpg")
        let temp = try tmp.file(".shrike-rename-X-IMG.jpg", "photo")
        _ = j.begin(moves: [(original, temp)])                 // written by this process, now
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: RenameJournal.processStart)                                // the real launch rule
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertTrue(exists(temp))
        XCTAssertEqual(j.pending().count, 1)
    }

    func testAnOldEntryOfADeadProcessIsHandled() async throws {
        let j = try journal()
        let original = tmp.url.appendingPathComponent("IMG.jpg")
        let temp = try tmp.file(".shrike-rename-X-IMG.jpg", "photo")
        j.write(RenameJournalEntry(id: UUID(), created: .distantPast,
                                   moves: [.init(original: original.path, temporary: temp.path)], pid: 999_999))
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date())
        XCTAssertEqual(report.restored, [original])
    }

    func testTheKernelProcessStartIsStableAndPlausible() {
        let first = RenameJournal.processStart
        XCTAssertEqual(first, RenameJournal.processStart, "the same value every time")
        XCTAssertLessThan(first, launchProbe, "this process started before setUp ran")
        XCTAssertGreaterThan(first, launchProbe.addingTimeInterval(-86_400))
        // Our parent (the test runner's launcher) started no later than we did.
        let parent = RenameJournal.startTime(ofPid: getppid())
        if let parent { XCTAssertLessThanOrEqual(parent, first) }
        XCTAssertNil(RenameJournal.startTime(ofPid: 999_999), "no such process")
    }

    func testTwoStepRenameKeepsTheEntryOnlyWhenThePhotoIsStranded() throws {
        struct Boom: Error {}
        let j = try journal()
        let a = tmp.url.appendingPathComponent("a"), t = tmp.url.appendingPathComponent("t"), b = tmp.url.appendingPathComponent("b")
        func run(failing: Set<Int>) -> Int {
            var call = 0
            _ = try? FileOps.twoStepRename(from: a, to: b, temp: t, journal: j, move: { _, _ in
                call += 1
                if failing.contains(call) { throw Boom() }
            })
            return j.pending().count
        }
        XCTAssertEqual(run(failing: []), 0, "success")
        XCTAssertEqual(run(failing: [1]), 0, "nothing moved")
        XCTAssertEqual(run(failing: [2]), 0, "second step failed, rollback worked")
        XCTAssertEqual(run(failing: [2, 3]), 1, "second step AND rollback failed: stranded, entry stays")
    }
}

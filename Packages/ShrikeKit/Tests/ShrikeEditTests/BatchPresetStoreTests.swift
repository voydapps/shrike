//
//  BatchPresetStoreTests.swift
//  ShrikeEditTests
//

import XCTest
import ShrikeCore
@testable import ShrikeEdit

final class BatchPresetStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent(BatchPresetStore.fileName) }

    func testDefaultURL_isUnderShrikeDataPaths() {
        XCTAssertEqual(BatchPresetStore.defaultURL.lastPathComponent, "BatchPresets.plist")
        XCTAssertTrue(BatchPresetStore.defaultURL.path.hasPrefix(ShrikeDataPaths.applicationSupport.path))
        XCTAssertFalse(BatchPresetStore.defaultURL.path.contains("/Library/Application Support/"),
                       "tests must not touch the user's Library")
    }

    func testBuiltIns_listedFirst() async {
        let names = await BatchPresetStore(fileURL: file).list().map(\.name)
        XCTAssertEqual(names, ["Web 2048", "Email 1280", "Rename by date"])
        XCTAssertEqual(BatchPresetStore.builtIns[0].resize?.value, 2048)
        XCTAssertEqual(BatchPresetStore.builtIns[1].convert?.quality ?? 0, 0.80, accuracy: 0.001)
    }

    func testSave_list_persists_andReplacesSameName() async throws {
        let store = BatchPresetStore(fileURL: file)
        let p = BatchPreset(name: "  Print 300  ", convert: ConvertOptions(format: .png),
                            resize: ResizeOptions(mode: .percent, value: 50), rotate: 1,
                            renameTemplate: "{name}_{counter:00}", renameStart: 5,
                            outputFolderPath: "/tmp/out")
        try await store.save(p)
        var again = BatchPreset(name: "print 300", rotate: 2)
        try await store.save(again)
        let reopened = await BatchPresetStore(fileURL: file).savedPresets()
        XCTAssertEqual(reopened.count, 1)
        again.name = "print 300"
        XCTAssertEqual(reopened.first, again)

        try await store.save(p)
        let byName = await BatchPresetStore(fileURL: file).savedPresets()
        XCTAssertEqual(byName.first?.name, "Print 300", "trimmed")
        XCTAssertEqual(byName.first?.renameStart, 5)
        XCTAssertEqual(byName.first?.resize, ResizeOptions(mode: .percent, value: 50))
    }

    func testRename_andDelete() async throws {
        let store = BatchPresetStore(fileURL: file)
        try await store.save(BatchPreset(name: "A"))
        try await store.save(BatchPreset(name: "B"))
        try await store.rename("a", to: "C")
        await XCTAssertThrowsErrorAsync(try await store.rename("C", to: "b"), .nameTaken("b"))
        await XCTAssertThrowsErrorAsync(try await store.rename("zzz", to: "Q"), .notFound("zzz"))
        try await store.delete(named: "B")
        let names = await BatchPresetStore(fileURL: file).savedPresets().map(\.name)
        XCTAssertEqual(names, ["C"])
    }

    func testBuiltInNames_andEmptyNames_refused() async {
        let store = BatchPresetStore(fileURL: file)
        await XCTAssertThrowsErrorAsync(try await store.save(BatchPreset(name: "web 2048")), .builtInName("web 2048"))
        await XCTAssertThrowsErrorAsync(try await store.save(BatchPreset(name: "   ")), .emptyName)
        await XCTAssertThrowsErrorAsync(try await store.delete(named: "Email 1280"), .builtInName("Email 1280"))
    }

    func testCorruptFile_readsAsEmpty() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: file)
        let list = await BatchPresetStore(fileURL: file).list()
        XCTAssertEqual(list.count, BatchPresetStore.builtIns.count)
    }

    func testMapsLink_signedCoordinates_encodedName() throws {
        let url = try XCTUnwrap(MapsLink.url(latitude: -33.86, longitude: 151.21, fileName: "Opera House #1.jpg"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://maps.apple.com/?ll=-33.860000,151.210000&q="), s)
        XCTAssertTrue(s.contains("Opera%20House%20%231.jpg"), s)
        XCTAssertNil(MapsLink.url(latitude: 91, longitude: 0, fileName: "x"))
    }

    private func XCTAssertThrowsErrorAsync(
        _ body: @autoclosure () async throws -> Void, _ expected: BatchPresetError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as BatchPresetError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

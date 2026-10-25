//
//  ExternalEditorTests.swift
//  ShrikeIOTests
//
//  Registry persistence, ordering and missing-app handling. Real system
//  apps (`/System/Applications/*.app`) are only read, never launched: a
//  fake workspace records every "open". No `.app` bundle is ever created
//  (project rule); a "missing" or "moved" app is a path that doesn't exist.
//

import XCTest
import Foundation
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
private final class FakeWorkspace: ApplicationWorkspace {
    var appsByBundleID: [String: URL] = [:]
    var appsForFile: [URL] = []
    var defaultApp: URL?
    var openError: (any Error)?
    private(set) var opened: [(urls: [URL], app: URL)] = []

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        appsByBundleID[bundleIdentifier]
    }
    func urlsForApplications(toOpen url: URL) -> [URL] { appsForFile }
    func urlForApplication(toOpen url: URL) -> URL? { defaultApp }
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        if let openError { throw openError }
        opened.append((urls, applicationURL))
    }
}

private struct LaunchError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class ExternalEditorTests: XCTestCase {

    private var dir: URL!
    private var defaults: UserDefaults!
    private var workspace: FakeWorkspace!
    private var photo: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("ShrikeExternalEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = makeTestDefaults()
        workspace = FakeWorkspace()
        photo = dir.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photo)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    // Read-only system apps. Never launched: `FakeWorkspace.open` records.
    private let previewApp = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
    private let textEditApp = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    private let imageCaptureApp = URL(fileURLWithPath: "/System/Applications/Image Capture.app", isDirectory: true)

    /// A path where no app exists (deleted / moved away).
    private func missingApp(_ name: String) -> URL {
        dir.appendingPathComponent("\(name).app", isDirectory: true)
    }

    private func makeRegistry() -> ExternalEditorRegistry {
        ExternalEditorRegistry(defaults: defaults, workspace: workspace)
    }

    // MARK: Model

    func testEditorFromApplicationBundle() throws {
        let editor = ExternalEditor(applicationAt: textEditApp)
        XCTAssertEqual(editor.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(editor.applicationURL, textEditApp)
        XCTAssertEqual(editor.displayName, ExternalEditor.displayName(ofApplicationAt: textEditApp))
        XCTAssertFalse(editor.displayName.hasSuffix(".app"))
    }

    // MARK: Persistence + ordering

    func testPersistenceRoundTripKeepsOrder() throws {
        let registry = makeRegistry()
        XCTAssertEqual(try registry.add(ExternalEditor(displayName: "Beta", bundleIdentifier: "com.example.beta")), 0)
        XCTAssertEqual(try registry.add(ExternalEditor(displayName: "Alpha", bundleIdentifier: "com.example.alpha",
                                                       applicationURL: previewApp)), 1)

        let reloaded = makeRegistry()
        XCTAssertEqual(reloaded.editors, registry.editors)
        XCTAssertEqual(reloaded.editors.map(\.displayName), ["Beta", "Alpha"])
        XCTAssertEqual(reloaded.editor(inSlot: 0)?.bundleIdentifier, "com.example.beta")
        XCTAssertNil(reloaded.editor(inSlot: 2))
        XCTAssertNotNil(defaults.data(forKey: ExternalEditorRegistry.defaultsKey))
    }

    func testMoveRenameRemovePersist() throws {
        let registry = makeRegistry()
        let ids = try (0..<4).map { i -> UUID in
            let editor = ExternalEditor(displayName: "E\(i)", bundleIdentifier: "com.example.e\(i)")
            try registry.add(editor)
            return editor.id
        }
        registry.move(fromSlot: 3, toSlot: 0)
        XCTAssertEqual(registry.editors.map(\.displayName), ["E3", "E0", "E1", "E2"])
        registry.rename(id: ids[1], to: "  Photoshop  ")
        registry.rename(id: ids[2], to: "   ")          // ignored
        registry.remove(id: ids[0])
        XCTAssertEqual(registry.editors.map(\.displayName), ["E3", "Photoshop", "E2"])
        XCTAssertEqual(registry.slot(of: ids[2]), 2)

        XCTAssertEqual(makeRegistry().editors.map(\.displayName), ["E3", "Photoshop", "E2"])

        registry.move(fromSlot: 0, toSlot: 9)             // out of range: no-op
        XCTAssertEqual(registry.editors.count, 3)
        registry.removeAll()
        XCTAssertTrue(makeRegistry().editors.isEmpty)
    }

    func testMaximumNineEditors() throws {
        let registry = makeRegistry()
        for i in 0..<9 {
            try registry.add(ExternalEditor(displayName: "E\(i)", bundleIdentifier: "com.example.\(i)"))
        }
        XCTAssertThrowsError(try registry.add(ExternalEditor(displayName: "Ten", bundleIdentifier: "com.example.ten"))) {
            XCTAssertEqual($0 as? ExternalEditorError, .registryFull)
        }
        XCTAssertEqual(registry.editors.count, ExternalEditorRegistry.maxEditors)
    }

    func testAddingSameAppTwiceReturnsExistingSlot() throws {
        let registry = makeRegistry()
        try registry.add(ExternalEditor(displayName: "A", bundleIdentifier: "com.example.a"))
        try registry.add(ExternalEditor(displayName: "B", bundleIdentifier: "com.example.b"))
        XCTAssertEqual(try registry.add(ExternalEditor(displayName: "B again", bundleIdentifier: "com.example.b")), 1)
        XCTAssertEqual(registry.editors.count, 2)
    }

    func testSetEditorInSlot() throws {
        let registry = makeRegistry()
        try registry.setEditor(ExternalEditor(displayName: "First"), inSlot: 0)
        try registry.setEditor(ExternalEditor(displayName: "Replaced"), inSlot: 0)
        XCTAssertEqual(registry.editors.map(\.displayName), ["Replaced"])
        XCTAssertThrowsError(try registry.setEditor(ExternalEditor(displayName: "Gap"), inSlot: 3)) {
            XCTAssertEqual($0 as? ExternalEditorError, .emptySlot(3))
        }
    }

    func testChangesPostNotification() throws {
        let registry = makeRegistry()
        let expectation = expectation(forNotification: ExternalEditorRegistry.didChangeNotification,
                                      object: registry)
        try registry.add(ExternalEditor(displayName: "A", bundleIdentifier: "com.example.a"))
        wait(for: [expectation], timeout: 1)
    }

    func testLegacySlotsImportedOnce() throws {
        let slots = [
            ExternalEditorSlot(name: "Legacy Tool", bundleIdentifierOrPath: previewApp.path),
            ExternalEditorSlot(name: "Unused", bundleIdentifierOrPath: ""),
            ExternalEditorSlot(name: "By ID", bundleIdentifierOrPath: "com.example.byid"),
        ]
        defaults.set(try JSONEncoder().encode(slots), forKey: ExternalEditorRegistry.legacyDefaultsKey)

        let registry = makeRegistry()
        XCTAssertEqual(registry.editors.map(\.displayName), ["Legacy Tool", "By ID"])
        XCTAssertEqual(registry.editors[0].bundleIdentifier, "com.apple.Preview")
        XCTAssertEqual(registry.editors[0].id, slots[0].id)
        XCTAssertEqual(registry.editors[1].bundleIdentifier, "com.example.byid")
        XCTAssertNil(registry.editors[1].applicationURL)

        // Once the registry has its own data, the legacy list is ignored.
        registry.remove(id: slots[2].id)
        XCTAssertEqual(makeRegistry().editors.map(\.displayName), ["Legacy Tool"])
    }

    // MARK: Launch + missing apps

    func testOpenLaunchesThroughWorkspace() async throws {
        let registry = makeRegistry()
        try registry.add(ExternalEditor(applicationAt: previewApp))
        try await registry.open([photo], slot: 0)
        XCTAssertEqual(workspace.opened.count, 1)
        XCTAssertEqual(workspace.opened.first?.urls, [photo])
        XCTAssertEqual(workspace.opened.first?.app, previewApp)
    }

    func testDeletedAppThrowsApplicationNotFound() async throws {
        // Stored path gone, and LaunchServices doesn't know the bundle id.
        let registry = makeRegistry()
        let editor = ExternalEditor(displayName: "Gone", bundleIdentifier: "com.example.gone",
                                    applicationURL: missingApp("Gone"))
        try registry.add(editor)

        XCTAssertFalse(registry.isAvailable(editor))
        do {
            try await registry.open([photo], with: editor)
            XCTFail("expected applicationNotFound")
        } catch {
            XCTAssertEqual(error as? ExternalEditorError, .applicationNotFound(name: "Gone"))
            XCTAssertNotNil((error as? any LocalizedError)?.errorDescription)
        }
        XCTAssertTrue(workspace.opened.isEmpty, "must not try to launch a missing app")
    }

    func testMovedAppIsFoundByBundleIdentifierAndRemembered() async throws {
        // The stored path no longer exists; LaunchServices finds the same
        // bundle id elsewhere (here: the real Preview.app, read only).
        let registry = makeRegistry()
        let editor = ExternalEditor(displayName: "Mover", bundleIdentifier: "com.apple.Preview",
                                    applicationURL: missingApp("Mover"))
        try registry.add(editor)
        let newApp = previewApp
        workspace.appsByBundleID["com.apple.Preview"] = newApp

        try await registry.open([photo], with: editor)
        XCTAssertEqual(workspace.opened.first?.app, newApp)
        XCTAssertEqual(registry.editors[0].applicationURL, newApp)
        XCTAssertEqual(makeRegistry().editors[0].applicationURL, newApp, "new location persisted")
    }

    func testMissingFileAndEmptySlotErrors() async throws {
        let registry = makeRegistry()
        try registry.add(ExternalEditor(applicationAt: previewApp))
        let missing = dir.appendingPathComponent("missing.jpg")
        do {
            try await registry.open([photo, missing], slot: 0)
            XCTFail("expected fileNotFound")
        } catch {
            XCTAssertEqual(error as? ExternalEditorError, .fileNotFound(missing))
        }
        do {
            try await registry.open([photo], slot: 4)
            XCTFail("expected emptySlot")
        } catch {
            XCTAssertEqual(error as? ExternalEditorError, .emptySlot(4))
        }
        try await registry.open([], slot: 0)   // no-op
        XCTAssertTrue(workspace.opened.isEmpty)
    }

    func testLaunchFailureIsWrapped() async throws {
        let registry = makeRegistry()
        try registry.add(ExternalEditor(displayName: "Flaky", bundleIdentifier: "com.apple.Preview",
                                        applicationURL: previewApp))
        workspace.openError = LaunchError()
        do {
            try await registry.open([photo], slot: 0)
            XCTFail("expected launchFailed")
        } catch {
            XCTAssertEqual(error as? ExternalEditorError, .launchFailed(name: "Flaky", reason: "boom"))
        }
    }

    // MARK: Discovery

    func testCandidatesDefaultFirstThenByNameWithoutDuplicates() throws {
        // Same bundle id twice (second spelling of the same path) must
        // collapse to one row.
        let duplicate = URL(fileURLWithPath: "/System/Applications/../Applications/Preview.app", isDirectory: true)
        workspace.appsForFile = [previewApp, imageCaptureApp, textEditApp, duplicate]
        workspace.defaultApp = textEditApp

        let candidates = makeRegistry().candidates(for: photo)
        let others = [previewApp, imageCaptureApp].map { ExternalEditor.displayName(ofApplicationAt: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(candidates.map(\.displayName),
                       [ExternalEditor.displayName(ofApplicationAt: textEditApp)] + others)
        XCTAssertEqual(candidates.map(\.isDefault), [true, false, false])
        XCTAssertEqual(candidates[0].editor.bundleIdentifier, "com.apple.TextEdit")
    }

    /// Read-only LaunchServices query against the real system; launches
    /// nothing.
    func testSystemWorkspaceFindsAppsForJPEG() {
        let apps = SystemApplicationWorkspace().urlsForApplications(toOpen: photo)
        XCTAssertFalse(apps.isEmpty, "macOS always has at least Preview for JPEG")
        let registry = ExternalEditorRegistry(defaults: defaults, workspace: SystemApplicationWorkspace())
        XCTAssertFalse(registry.candidates(for: photo).isEmpty)
    }

    // MARK: Send RAW + groups
    //
    // These use the real Preview.app as the app location (read only) and
    // the fake workspace for "open", so nothing is launched and no fake
    // app bundle is created.

    private func pair() throws -> ImageGroup {
        let raw = dir.appendingPathComponent("photo.ORF")
        let xmp = dir.appendingPathComponent("photo.xmp")
        try Data("raw".utf8).write(to: raw)
        try Data("xmp".utf8).write(to: xmp)
        let groups = ImageGrouping.group([photo, raw, xmp], options: .default)
        XCTAssertEqual(groups.count, 1)
        return groups[0]
    }

    func testSendRAWDefaultsOffAndOldDataDecodes() throws {
        XCTAssertFalse(ExternalEditor(displayName: "X").sendRAW)
        let old = #"[{"id":"\#(UUID().uuidString)","displayName":"Old","bundleIdentifier":"com.apple.Preview"}]"#
        defaults.set(Data(old.utf8), forKey: ExternalEditorRegistry.defaultsKey)
        let registry = makeRegistry()
        XCTAssertEqual(registry.editors.count, 1)
        XCTAssertFalse(registry.editors[0].sendRAW)
    }

    func testSetSendRAWPersists() throws {
        let registry = makeRegistry()
        try registry.add(ExternalEditor(displayName: "Preview", applicationURL: previewApp))
        registry.setSendRAW(true, for: registry.editors[0].id)
        XCTAssertTrue(makeRegistry().editors[0].sendRAW)
    }

    func testOpenGroupSendsJPEGByDefault() async throws {
        let group = try pair()
        let registry = makeRegistry()
        try registry.add(ExternalEditor(displayName: "Preview", applicationURL: previewApp))
        try await registry.open(group, slot: 0)
        XCTAssertEqual(workspace.opened.first?.urls, [photo])
        XCTAssertEqual(workspace.opened.first?.app, previewApp)
    }

    func testOpenGroupSendsRAWWhenSendRAWIsOn() async throws {
        // Send RAW on, pair item → the ORF opens.
        let group = try pair()
        let registry = makeRegistry()
        try registry.add(ExternalEditor(displayName: "Preview", applicationURL: previewApp, sendRAW: true))
        try await registry.open(group, slot: 0)
        XCTAssertEqual(workspace.opened.first?.urls.map(\.lastPathComponent), ["photo.ORF"])
    }

    func testSendRAWWithoutRAWSendsPrimary() async throws {
        let solo = ImageGroup(primary: photo)
        let editor = ExternalEditor(displayName: "Preview", applicationURL: previewApp, sendRAW: true)
        XCTAssertEqual(editor.file(for: solo), photo)
        let registry = makeRegistry()
        try await registry.open(groups: [solo, solo], with: editor)
        XCTAssertEqual(workspace.opened.first?.urls, [photo], "duplicates removed")
    }

    func testOpenGroupInEmptySlotThrows() async throws {
        let group = try pair()
        do {
            try await makeRegistry().open(group, slot: 3)
            XCTFail("expected emptySlot")
        } catch {
            XCTAssertEqual(error as? ExternalEditorError, .emptySlot(3))
        }
    }

    func testValidateAppURL() throws {
        let editor = try XCTUnwrap(ExternalEditor.validate(appURL: previewApp))
        XCTAssertEqual(editor.bundleIdentifier, "com.apple.Preview")
        XCTAssertEqual(editor.displayName, "Preview")
        XCTAssertFalse(editor.sendRAW)
        XCTAssertNil(ExternalEditor.validate(appURL: dir), "plain folder")
        XCTAssertNil(ExternalEditor.validate(appURL: photo), "a file")
        XCTAssertNil(ExternalEditor.validate(appURL: dir.appendingPathComponent("Missing.app")))
        XCTAssertNil(ExternalEditor.validate(appURL: URL(string: "https://example.com/x.app")!))
    }

    @MainActor
    func testRegistryKeyIsListedForResetAll() {
        XCTAssertTrue(Prefs.Key.allKeys.contains(ExternalEditorRegistry.defaultsKey))
        XCTAssertTrue(Prefs.Key.allKeys.contains(ImageGroupingPreference.key))
    }

}

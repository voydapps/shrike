import AppKit
import UniformTypeIdentifiers
import XCTest
import ShrikeCore
import ShrikeIO
@testable import ShrikeUI

private actor FolderListingGate {
    var folders: [URL] = []
    private var released = false
    var continuations: [Int: CheckedContinuation<[BrowserItem], any Error>] = [:]
    func scan(_ folder: URL) async throws -> [BrowserItem] {
        let index = folders.count
        folders.append(folder)
        if released { return [] }
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func count() -> Int { folders.count }
    func finish(_ index: Int, _ items: [BrowserItem]) { continuations.removeValue(forKey: index)?.resume(returning: items) }
    func fail(_ index: Int, _ error: any Error) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
    func releaseAll() {
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: []) }
    }
}

@MainActor
final class BrowserRequestTests: XCTestCase {
    private func item(_ folder: URL, _ name: String, rating: Int = 0) -> BrowserItem {
        BrowserItem(url: folder.appendingPathComponent(name), displayName: name, fileSize: 1,
                    modificationDate: Date(), creationDate: nil, captureDate: nil, utType: .jpeg,
                    pixelWidth: nil, pixelHeight: nil, rating: rating)
    }
    private func until(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Controlled folder request did not settle")
    }

    func testOlderFolderCannotReplaceNewerFolderOrItsIdentity() async throws {
        let gate = FolderListingGate()
        let a = URL(fileURLWithPath: "/tmp/shrike-A"), b = URL(fileURLWithPath: "/tmp/shrike-B")
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: a,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        try await until { await gate.count() == 1 }
        browser.navigate(to: b)
        try await until { await gate.count() == 2 }
        await gate.finish(1, [item(b, "b.jpg")])
        try await until { browser.contentController.allItems.first?.displayName == "b.jpg" }
        await gate.finish(0, [item(a, "a.jpg")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(browser.currentFolder, b)
        XCTAssertEqual(browser.window?.representedURL, b)
        XCTAssertEqual(browser.window?.title, b.lastPathComponent)
        XCTAssertEqual(browser.contentController.selectedItems.first?.url, b.appendingPathComponent("b.jpg"))
        XCTAssertEqual(browser.contentController.allItems.first?.displayName, "b.jpg")
    }

    func testSameFolderReloadAndReturnRejectOlderRequests() async throws {
        let gate = FolderListingGate()
        let a = URL(fileURLWithPath: "/tmp/shrike-A"), b = URL(fileURLWithPath: "/tmp/shrike-B")
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: a,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        try await until { await gate.count() == 1 }
        browser.navigate(to: b)
        try await until { await gate.count() == 2 }
        browser.navigate(to: a)
        try await until { await gate.count() == 3 }
        await gate.finish(2, [item(a, "new.jpg")])
        try await until { browser.contentController.allItems.first?.displayName == "new.jpg" }
        await gate.finish(0, [item(a, "old.jpg")])
        await gate.finish(1, [item(b, "b.jpg")])
        browser.reloadCurrentFolder()
        try await until { await gate.count() == 4 }
        browser.reloadCurrentFolder()
        try await until { await gate.count() == 5 }
        await gate.finish(4, [item(a, "latest.jpg")])
        try await until { browser.contentController.allItems.first?.displayName == "latest.jpg" }
        await gate.finish(3, [item(a, "stale.jpg")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(browser.contentController.allItems.first?.displayName, "latest.jpg")
        XCTAssertEqual(browser.window?.representedURL, a)
    }

    func testNewFolderLoadingClearsPreviousActionTargets() async throws {
        let gate = FolderListingGate()
        let a = URL(fileURLWithPath: "/tmp/shrike-target-A"), b = URL(fileURLWithPath: "/tmp/shrike-target-B")
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: a,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        try await until { await gate.count() == 1 }
        await gate.finish(0, [item(a, "a.jpg")])
        try await until { !browser.contentController.selectedItems.isEmpty }
        browser.navigate(to: b)
        XCTAssertTrue(browser.contentController.allItems.isEmpty)
        XCTAssertTrue(browser.contentController.selectedItems.isEmpty)
        XCTAssertEqual(browser.window?.representedURL, b)
        XCTAssertTrue(browser.contentController.emptyStateForTesting?.titleText.hasPrefix("Opening") == true)
        try await until { await gate.count() == 2 }
        await gate.fail(1, FolderScannerError.permissionDenied(b))
        try await until { browser.contentController.emptyStateForTesting?.buttonTitle == "Retry" }
        XCTAssertTrue(browser.contentController.selectedItems.isEmpty)
    }

    func testFolderErrorsAreRetryableAndEmptySuccessIsDistinct() async throws {
        let gate = FolderListingGate()
        let folder = URL(fileURLWithPath: "/tmp/shrike-unreadable")
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: folder,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        try await until { await gate.count() == 1 }
        await gate.fail(0, FolderScannerError.permissionDenied(folder))
        try await until { browser.contentController.emptyStateForTesting?.buttonTitle == "Retry" }
        XCTAssertTrue(browser.contentController.emptyStateForTesting?.subtitleText?.contains("permission") == true)
        browser.contentController.emptyStateForTesting?.button.performClick(nil)
        try await until { await gate.count() == 2 }
        await gate.fail(1, FolderScannerError.unreadable(folder, reason: "Disk could not be read."))
        try await until { browser.contentController.emptyStateForTesting?.subtitleText == "Disk could not be read." }
        browser.contentController.emptyStateForTesting?.button.performClick(nil)
        try await until { await gate.count() == 3 }
        await gate.finish(2, [])
        try await until { browser.contentController.emptyStateForTesting?.titleText.hasPrefix("No photos") == true }
        XCTAssertNil(browser.contentController.emptyStateForTesting?.buttonTitle)
        browser.reloadCurrentFolder()
        try await until { await gate.count() == 4 }
        await gate.fail(3, FolderScannerError.notADirectory(folder))
        try await until { browser.contentController.emptyStateForTesting?.buttonTitle == "Go to Enclosing Folder" }
        XCTAssertNil(browser.folderWatcher)
    }

    func testOldSameFolderHydrateCannotReplaceNewListing() async throws {
        let gate = FolderListingGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-hydrate-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Photos", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("same.jpg")
        try Data().write(to: url)
        let store = try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false })
        try await store.setRating(1, for: url)
        let services = ShrikeServices(thumbnailCache: ShrikeServices.makeDefault().thumbnailCache, metadataStore: store)
        let browser = BrowserWindowController(services: services, initialFolder: folder,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        var pending: CheckedContinuation<Void, Never>?
        var first = true
        var hydrated = 0
        browser.onHydratedForTesting = { hydrated += 1 }
        browser.hydrationGateForTesting = {
            if first {
                first = false
                await withCheckedContinuation { pending = $0 }
            }
        }
        try await until { await gate.count() == 1 }
        await gate.finish(0, [item(folder, "same.jpg")])
        try await until { pending != nil }
        // The first hydration holds rating 1 for this exact URL. The
        // accepted reload must remain 5 after that older snapshot lands.
        try await store.setRating(5, for: url)
        browser.contentController.select(url: url)
        browser.reloadCurrentFolder()
        try await until { await gate.count() == 2 }
        await gate.finish(1, [item(folder, "same.jpg")])
        try await until { hydrated == 1 }
        pending?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(browser.contentController.allItems.first?.rating, 5)
        XCTAssertEqual(browser.contentController.selectedItems.map(\.url), [url])
        XCTAssertEqual(browser.window?.representedURL, folder)
        XCTAssertEqual(hydrated, 1, "the superseded hydrate does not publish a completion")
    }

    func testCloseInvalidatesSuspendedScan() async throws {
        let gate = FolderListingGate()
        let folder = URL(fileURLWithPath: "/tmp/shrike-closing")
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: folder,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        try await until { await gate.count() == 1 }
        browser.close()
        await gate.finish(0, [item(folder, "late.jpg")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(browser.browserDidClose)
        XCTAssertTrue(browser.contentController.allItems.isEmpty)
        XCTAssertEqual(browser.window?.representedURL, folder)
        XCTAssertNil(browser.folderWatcher)
    }
    func testLateHiddenPolicyListingCannotReplaceNewFolderSelectionOrHistory() async throws {
        let key = "shrike.browser.showHiddenFiles", saved = ShrikeDefaults.store.object(forKey: "shrike.browser.showHiddenFiles")
        defer {
            if let saved { ShrikeDefaults.store.set(saved, forKey: key) }
            else { ShrikeDefaults.store.removeObject(forKey: key) }
            NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
        }
        Prefs.showHiddenFiles = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-hidden-request-\(UUID())", isDirectory: true).standardizedFileURL
        let a = root.appendingPathComponent("A", isDirectory: true), b = root.appendingPathComponent("B", isDirectory: true)
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SaveFlowTests.writeImage(folder.appendingPathComponent("Visible.jpg"), type: .jpeg)
        }
        try SaveFlowTests.writeImage(a.appendingPathComponent(".Hidden.jpg"), type: .jpeg)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FolderListingGate(), store = PreferencesStore()
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: a,
            folderEnumerator: { folder, _ in try await gate.scan(folder) })
        defer { browser.close() }
        var held: Task<Void, Never>?
        do {
            try await until { await gate.count() == 1 }
            await gate.finish(0, [item(a, "Visible.jpg")])
            try await until { browser.contentController.selectedItems.map(\.url) == [a.appendingPathComponent("Visible.jpg")] }
            store.showHiddenFiles.wrappedValue = true
            try await until { await gate.count() == 2 }
            held = browser.listingTask
            browser.navigate(to: b)
            try await until { await gate.count() == 3 }
            await gate.finish(2, [item(b, "Visible.jpg")])
            try await until { browser.contentController.selectedItems.map(\.url) == [b.appendingPathComponent("Visible.jpg")] }
            let content = browser.contentController, visible = b.appendingPathComponent("Visible.jpg")
            content.setMode(.grid)
            content.collectionViewForTesting.noteClick(on: IndexPath(item: 0, section: 0), command: false)
            XCTAssertEqual(content.selectionAnchorURL, visible)
            store.showHiddenFiles.wrappedValue = false
            try await until { await gate.count() == 4 }
            await gate.finish(3, [item(b, "Visible.jpg")])
            try await until { content.visibleItems.map(\.url) == [visible] && !content.isHydratingMarks }
            let generation = browser.folderRequestGeneration
            await gate.finish(1, [item(a, "Visible.jpg"), item(a, ".Hidden.jpg")])
            await held?.value
            XCTAssertEqual(browser.folderRequestGeneration, generation)
            XCTAssertEqual(browser.currentFolder, b)
            XCTAssertEqual(browser.window?.representedURL, b)
            XCTAssertEqual(browser.window?.title, b.lastPathComponent)
            XCTAssertEqual(content.visibleItems.map(\.url), [visible])
            XCTAssertEqual(content.selectedItems.map(\.url), [visible])
            XCTAssertEqual(content.selectionAnchorURL, visible)
            XCTAssertEqual(browser.backStack, [a])
            XCTAssertTrue(browser.forwardStack.isEmpty)
        } catch {
            await gate.releaseAll()
            await held?.value
            await browser.listingTask?.value
            throw error
        }
        await gate.releaseAll()
        await browser.listingTask?.value
    }

}

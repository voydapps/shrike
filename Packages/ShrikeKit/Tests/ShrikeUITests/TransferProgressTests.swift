import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

/// Actual FileOps streams and the production Browser/Viewer toast callbacks.
/// The conflict continuation holds work until progress is observed, not for an
/// assumed disk speed or fixed conflict-sheet dwell.
@MainActor
final class TransferProgressTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var trash: URL!
    private var previousDelay: Duration!

    override func setUp() async throws {
        _ = NSApplication.shared
        previousDelay = FileTransferCoordinator.progressDelay
        FileTransferCoordinator.progressDelay = .milliseconds(30)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-transfer-progress-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        for folder in [source!, destination!, trash!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        FileTransferCoordinator.progressDelay = previousDelay
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private final class ConflictGate {
        var continuation: CheckedContinuation<ConflictAnswer, Never>?
        private var answerForLateWaiter: ConflictAnswer?
        func wait() async -> ConflictAnswer {
            if let answerForLateWaiter { return answerForLateWaiter }
            return await withCheckedContinuation { continuation = $0 }
        }
        func answer(_ choice: ConflictAnswer.Action = .skip) {
            // Cleanup may run before FileOps has reached its conflict callback.
            // Keep that explicit answer so a late callback cannot strand work.
            let answer = ConflictAnswer(choice)
            answerForLateWaiter = answer
            let pending = continuation
            continuation = nil
            pending?.resume(returning: answer)
        }
    }

    @MainActor
    private final class CompletionFlag { var finished = false }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Observe completion without an unbounded `.value` wait in the test body.
    /// A failed precondition cancels the real operation and releases its gate;
    /// the release also covers a conflict callback that has not arrived yet.
    private func finish(_ task: Task<Void, Never>?, gate: ConflictGate? = nil,
                        cancel: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        guard let task else {
            XCTFail("Expected a real transfer task", file: file, line: line)
            gate?.answer()
            return false
        }
        if cancel { task.cancel(); gate?.answer() }
        let flag = CompletionFlag()
        let observer = Task { @MainActor in
            await task.value
            flag.finished = true
        }
        let completed = await waitUntil { flag.finished }
        XCTAssertTrue(completed, "Transfer must finish within the existing 3-second deadline",
                      file: file, line: line)
        if !completed {
            task.cancel()
            gate?.answer()
            let cleaned = await waitUntil { flag.finished }
            XCTAssertTrue(cleaned, "Cancelled transfer must release its conflict and finish",
                          file: file, line: line)
            if !cleaned { observer.cancel() }
        }
        return completed
    }

    private func heldProgress(_ gate: ConflictGate, host: ToastHostView,
                              task: Task<Void, Never>?,
                              file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let ready = await waitUntil { gate.continuation != nil && host.content?.progress != nil }
        XCTAssertTrue(ready, "Conflict must be awaiting an answer while actual progress is visible",
                      file: file, line: line)
        guard ready else {
            _ = await finish(task, gate: gate, cancel: true, file: file, line: line)
            return false
        }
        do {
            let bar = try progressBar(in: host, file: file, line: line)
            let visible = !bar.isHiddenOrHasHiddenAncestor
            XCTAssertTrue(visible, "The real held progress indicator must be visible before answering the installed conflict gate",
                          file: file, line: line)
            XCTAssertTrue(bar.isIndeterminate, "A group-level transfer with no completed work must expose native busy progress",
                          file: file, line: line)
            XCTAssertEqual(host.content?.progress, 0, "Busy presentation must not invent completed work",
                           file: file, line: line)
            if !visible { _ = await finish(task, gate: gate, cancel: true, file: file, line: line) }
            return visible
        } catch {
            _ = await finish(task, gate: gate, cancel: true, file: file, line: line)
            return false
        }
    }

    private func image(_ name: String, in folder: URL, white: CGFloat) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6,
                                             bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let pixels = try XCTUnwrap(context.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                      UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, pixels, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        return url
    }

    private func files() throws -> (URL, URL, URL) {
        let first = try image("conflict.png", in: source, white: 0.2)
        let existing = try image("conflict.png", in: destination, white: 0.8)
        let next = try image("next.png", in: source, white: 0.5)
        return (first, existing, next)
    }

    private func ops() -> FileOps {
        let trash = trash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
    }

    private func viewer(_ urls: [URL]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let window = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
                                  services: services)
        window.fileOps = ops()
        window.markDisplayedForTesting(0)
        return window
    }

    private func assertHidden(_ host: ToastHostView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(host.content, file: file, line: line)
        XCTAssertFalse(host.isShowing, file: file, line: line)
        XCTAssertFalse(host.isAccessibilityElement(), file: file, line: line)
    }

    private func progressBar(in host: ToastHostView,
                             file: StaticString = #filePath, line: UInt = #line) throws -> NSProgressIndicator {
        func indicators(in view: NSView) -> [NSProgressIndicator] {
            ((view as? NSProgressIndicator).map { [$0] } ?? []) + view.subviews.flatMap { indicators(in: $0) }
        }
        // HUDSurfaceView redirects added content into its contentHost.
        let bars = indicators(in: host)
        XCTAssertEqual(bars.count, 1, "Toast must contain exactly one real progress indicator across its nested content",
                       file: file, line: line)
        return try XCTUnwrap(bars.first, "Missing real progress indicator in toast content hierarchy",
                             file: file, line: line)
    }

    private func assertSettledHidden(_ host: ToastHostView,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        assertHidden(host, file: file, line: line)
        let hidden = await waitUntil { host.isHidden }
        XCTAssertTrue(hidden, "Toast host must finish fading and become hidden within the existing 3-second deadline",
                      file: file, line: line)
        do {
            let bar = try progressBar(in: host, file: file, line: line)
            XCTAssertTrue(bar.isHiddenOrHasHiddenAncestor, "The real progress indicator must have a hidden ancestor after toast dismissal",
                          file: file, line: line)
        } catch {
            // XCTUnwrap above records the distinct missing-indicator failure.
        }
    }

    func testBrowserHeldCopySkipClearsProgressAndDoesNotRegisterUndo() async throws {
        let (first, existing, _) = try files()
        let original = try Data(contentsOf: first)
        let previous = try Data(contentsOf: existing)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: source)
        defer { browser.close() }
        browser.fileOps = ops()
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(loaded)
        let gate = ConflictGate()
        browser.transfers.conflictResponder = { _ in await gate.wait() }
        browser.transfer(.copy, [ImageGroup(primary: first)], to: destination)
        guard await heldProgress(gate, host: browser.toastHost, task: browser.trashChain) else { return }
        XCTAssertTrue(browser.transfers.isShowingProgress)
        gate.answer()
        guard await finish(browser.trashChain, gate: gate) else { return }
        await assertSettledHidden(browser.toastHost)
        XCTAssertFalse(browser.transfers.isShowingProgress)
        XCTAssertFalse(browser.window?.undoManager?.canUndo ?? true)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
    }

    func testViewerHeldMoveSkipRestoresMembershipAndClearsProgress() async throws {
        let (first, existing, next) = try files()
        let original = try Data(contentsOf: first)
        let previous = try Data(contentsOf: existing)
        let window = viewer([first, next])
        defer { window.close() }
        let gate = ConflictGate()
        window.transfers.conflictResponder = { _ in await gate.wait() }
        window.transfer(.move, ImageGroup(primary: first), to: destination)
        XCTAssertEqual(window.groups.map(\.primary), [next])
        guard await heldProgress(gate, host: window.contentRoot.toastHost, task: window.trashChain) else { return }
        gate.answer()
        guard await finish(window.trashChain, gate: gate) else { return }
        await assertSettledHidden(window.contentRoot.toastHost)
        XCTAssertFalse(window.transfers.isShowingProgress)
        XCTAssertEqual(window.groups.map(\.primary), [first, next])
        XCTAssertFalse(window.undoManagerForTesting.canUndo)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
    }

    func testFastSkipCancelsDelayedProgressWithoutHidingExistingNotice() async throws {
        FileTransferCoordinator.progressDelay = .milliseconds(150)
        let (first, _, next) = try files()
        let window = viewer([first, next])
        defer { window.close() }
        let host = window.contentRoot.toastHost
        var announcements: [String] = []
        host.announce = { message, _ in announcements.append(message) }
        host.show("Existing notice")
        window.transfers.conflictResponder = { _ in .skip }
        window.transfer(.copy, ImageGroup(primary: first), to: destination)
        guard await finish(window.trashChain) else { return }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(host.content?.message, "Existing notice")
        XCTAssertNil(host.content?.progress)
        XCTAssertEqual(announcements, ["Existing notice"], "fast Skip never shows progress")
        XCTAssertFalse(window.transfers.isShowingProgress)
        XCTAssertFalse(window.undoManagerForTesting.canUndo)
    }

    func testHeldSkipPreservesNewerPlainAndProgressPresentations() async throws {
        for replacementIsProgress in [false, true] {
            let (first, existing, next) = try files()
            let original = try Data(contentsOf: first)
            let previous = try Data(contentsOf: existing)
            let window = viewer([first, next])
            defer { window.close() }
            let host = window.contentRoot.toastHost
            let gate = ConflictGate()
            window.transfers.conflictResponder = { _ in await gate.wait() }
            window.transfer(.copy, ImageGroup(primary: first), to: destination)
            guard await heldProgress(gate, host: host, task: window.trashChain) else { return }
            var replacement = ToastContent("Newer presentation", kind: .error)
            if replacementIsProgress { replacement.progress = 0.5 }
            host.show(replacement)
            gate.answer()
            guard await finish(window.trashChain, gate: gate) else { return }
            XCTAssertEqual(host.content, replacement)
            XCTAssertFalse(window.transfers.isShowingProgress)
            XCTAssertEqual(try Data(contentsOf: first), original)
            XCTAssertEqual(try Data(contentsOf: existing), previous)
        }
    }

    func testQueuedSuccessorAfterHeldSkipKeepsFiniteCompletionAndOneRealUndo() async throws {
        let (first, existing, next) = try files()
        let previous = try Data(contentsOf: existing)
        let nextBytes = try Data(contentsOf: next)
        let window = viewer([first, next])
        defer { window.close() }
        let gate = ConflictGate()
        window.transfers.conflictResponder = { _ in await gate.wait() }
        window.transfer(.copy, ImageGroup(primary: first), to: destination)
        guard await heldProgress(gate, host: window.contentRoot.toastHost, task: window.trashChain) else { return }
        window.transfer(.copy, ImageGroup(primary: next), to: destination)
        gate.answer()
        guard await finish(window.trashChain, gate: gate) else { return }
        let landed = destination.appendingPathComponent("next.png")
        XCTAssertEqual(try Data(contentsOf: landed), nextBytes)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
        XCTAssertEqual(window.contentRoot.toastHost.content?.message, "Copied “next.png” to “Destination”.")
        XCTAssertNil(window.contentRoot.toastHost.content?.progress)
        XCTAssertEqual(window.contentRoot.toastHost.actionTitleForTesting, "Undo")
        XCTAssertEqual(window.undoManagerForTesting.undoActionName, "Copy")
        window.performUndo()
        guard await finish(window.trashChain) else { return }
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        XCTAssertEqual(try Data(contentsOf: existing), previous)
        XCTAssertFalse(window.undoManagerForTesting.canUndo, "Skip adds no empty Undo step")
    }

    func testCancellationBeforeDelayCannotShowProgressAfterCompletion() async throws {
        FileTransferCoordinator.progressDelay = .milliseconds(150)
        let (first, _, next) = try files()
        let window = viewer([first, next])
        defer { window.close() }
        let gate = ConflictGate()
        window.transfers.conflictResponder = { _ in await gate.wait() }
        let coordinator = window.transfers
        let operation = ops()
        var outcome: FileTransferCoordinator.Outcome?
        let task = Task { @MainActor in
            outcome = await coordinator.run(.copy, [ImageGroup(primary: first)], to: destination, ops: operation)
        }
        let waiting = await waitUntil { gate.continuation != nil }
        XCTAssertTrue(waiting)
        guard waiting else {
            _ = await finish(task, gate: gate, cancel: true)
            return
        }
        task.cancel()
        gate.answer()
        guard await finish(task, gate: gate) else { return }
        let result = try XCTUnwrap(outcome)
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.items.isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        assertHidden(window.contentRoot.toastHost)
        XCTAssertFalse(coordinator.isShowingProgress)
    }

    func testShownProgressCancellationRetainsFiniteCancellationFeedback() async throws {
        let (first, existing, next) = try files()
        let previous = try Data(contentsOf: existing)
        let window = viewer([first, next])
        defer { window.close() }
        let gate = ConflictGate()
        window.transfers.conflictResponder = { _ in await gate.wait() }
        window.transfer(.copy, ImageGroup(primary: first), to: destination)
        guard await heldProgress(gate, host: window.contentRoot.toastHost, task: window.trashChain) else { return }
        XCTAssertTrue(window.transfers.cancelRunning())
        gate.answer()
        guard await finish(window.trashChain, gate: gate) else { return }
        XCTAssertEqual(window.contentRoot.toastHost.content?.message,
                       "Copied 0 of 1 items. The rest were cancelled.")
        XCTAssertNil(window.contentRoot.toastHost.content?.progress)
        XCTAssertFalse(window.transfers.isShowingProgress)
        XCTAssertFalse(window.undoManagerForTesting.canUndo)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
    }

    func testErrorAfterShownProgressRetainsFiniteErrorFeedback() async throws {
        let (first, existing, _) = try files()
        let previous = try Data(contentsOf: existing)
        let gate = ConflictGate()
        let operation = ops()
        let missing = source.appendingPathComponent("missing.png")
        // Browser accepts a snapshotted multi-selection. The second file can
        // disappear externally while the first conflict awaits an answer.
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: source)
        defer { browser.close() }
        browser.fileOps = operation
        browser.transfers.conflictResponder = { _ in await gate.wait() }
        browser.transfer(.copy, [ImageGroup(primary: first), ImageGroup(primary: missing)], to: destination)
        guard await heldProgress(gate, host: browser.toastHost, task: browser.trashChain) else { return }
        gate.answer()
        guard await finish(browser.trashChain, gate: gate) else { return }
        XCTAssertEqual(browser.toastHost.content?.kind, .error)
        XCTAssertNil(browser.toastHost.content?.progress)
        XCTAssertFalse(browser.transfers.isShowingProgress)
        XCTAssertFalse(browser.window?.undoManager?.canUndo ?? true)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
    }

    func testProgressTicketsAreHostSpecificLatestAndIdempotent() throws {
        let host = ToastHostView(placement: .viewer)
        let other = ToastHostView(placement: .browser)
        var first = ToastContent("First")
        first.progress = 0
        let oldTicket = host.showProgress(first)
        let otherTicket = other.showProgress(first)
        var refreshed = first
        refreshed.progress = 0.5
        let latest = try XCTUnwrap(host.updateProgress(refreshed, matching: oldTicket))
        XCTAssertNil(host.updateProgress(first, matching: oldTicket))
        XCTAssertNil(host.updateProgress(first, matching: otherTicket))
        host.dismissProgress(matching: oldTicket)
        XCTAssertEqual(host.content, refreshed)
        host.dismissProgress(matching: otherTicket)
        XCTAssertEqual(host.content, refreshed)
        host.dismissProgress(matching: latest)
        assertHidden(host)
        host.dismissProgress(matching: latest)
        assertHidden(host)
        XCTAssertEqual(other.content, first)
        other.dismiss(animated: false)
    }

    func testTicketDoesNotRetainReleasedHostOrClosedViewer() async throws {
        var host: ToastHostView? = ToastHostView(placement: .viewer)
        weak var weakHost = host
        var progress = ToastContent("Progress")
        progress.progress = 0
        let ticket = try XCTUnwrap(host?.showProgress(progress))
        host?.dismiss(animated: false)
        host = nil
        let hostReleased = await waitUntil { weakHost == nil }
        XCTAssertTrue(hostReleased)
        let replacement = ToastHostView(placement: .viewer)
        replacement.show("Replacement")
        replacement.dismissProgress(matching: ticket)
        XCTAssertEqual(replacement.content?.message, "Replacement")
        replacement.dismiss(animated: false)

        let (first, _, next) = try files()
        var window: ViewerWindow? = viewer([first, next])
        weak var weakWindow = window
        let coordinator = try XCTUnwrap(window?.transfers)
        window?.close()
        window = nil
        let released = await waitUntil { weakWindow == nil }
        XCTAssertTrue(released, "holding the transfer coordinator must not retain its window")
        XCTAssertNil(coordinator.showProgressToast(progress))
        coordinator.dismissProgressToast(ticket)
    }
}

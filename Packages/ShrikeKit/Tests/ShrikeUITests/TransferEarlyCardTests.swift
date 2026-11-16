//
//  TransferEarlyCardTests.swift
//  ShrikeUITests
//
//  Pass 2p task 2: a copy / move of several photos shows its progress card
//  at once when the user chose the destination (the reservation), the run
//  takes that same card over and updates it in place, and every exit
//  removes it. Window-free: the coordinator's toast callbacks are recorded.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class TransferEarlyCardTests: XCTestCase {

    /// One progress band, like the Browser's: a show replaces, a ticket is the latest generation.
    @MainActor private final class FakeBand {
        var shown: [String] = []
        var updates = 0
        var current: ToastContent?
        var generation = 0
        func show(_ content: ToastContent) -> TransferProgressTicket {
            generation += 1
            shown.append(content.message)
            current = content
            return TransferProgressTicket(owner: self, generation: generation)
        }
        func update(_ content: ToastContent, _ ticket: TransferProgressTicket) -> TransferProgressTicket? {
            guard ticket.owner === self, ticket.generation == generation, current != nil else { return nil }
            updates += 1
            generation += 1
            current = content
            return TransferProgressTicket(owner: self, generation: generation)
        }
        /// Another notice takes the band (an earlier operation's result).
        func replaceWithNotice() {
            generation += 1
            current = ToastContent("Moved 2 items to “Trips”.")
        }
        func dismiss(_ ticket: TransferProgressTicket) {
            guard ticket.owner === self, ticket.generation == generation else { return }
            current = nil
        }
    }

    private var band: FakeBand!
    private var coordinator: FileTransferCoordinator!
    private var root: URL!
    private var previousDelay: Duration!

    override func setUp() async throws {
        previousDelay = FileTransferCoordinator.progressDelay
        band = FakeBand()
        coordinator = FileTransferCoordinator(window: nil)
        let band = band!
        coordinator.showProgressToast = { band.show($0) }
        coordinator.updateProgressToast = { band.update($0, $1) }
        coordinator.dismissProgressToast = { band.dismiss($0) }
        coordinator.ownsProgressToast = { $0.owner === band && $0.generation == band.generation && band.current != nil }
        root = TestScratch.directory.appendingPathComponent("shrike-2p2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        FileTransferCoordinator.progressDelay = previousDelay
        try? FileManager.default.removeItem(at: root)
    }

    func testStartingTextAndNoCardForOnePhoto() {
        let content = FileTransferCoordinator.startingContent(.copy, total: 2000)
        XCTAssertEqual(content.message, "Copying 1 of 2000…")
        XCTAssertTrue(content.progressIsIndeterminate)
        XCTAssertEqual(FileTransferCoordinator.startingContent(.move, total: 8).message, "Moving 1 of 8…")

        let one = coordinator.reserveShowingProgress(.copy, total: 1)
        XCTAssertEqual(band.shown, [], "a single photo shows no card (a quick copy would flash it)")
        FileTransferCoordinator.release(one)
    }

    func testReleaseRemovesTheCardOnEveryEarlyExit() {
        // Already in this folder, window gone, an error before the run: all release.
        let reservation = coordinator.reserveShowingProgress(.move, total: 5)
        XCTAssertEqual(band.shown, ["Moving 1 of 5…"], "the card shows at once")
        XCTAssertNotNil(band.current)
        XCTAssertEqual(FileTransferCoordinator.runningWork.count, 1)
        FileTransferCoordinator.release(reservation)
        XCTAssertNil(band.current, "released: the card is gone")
        XCTAssertTrue(FileTransferCoordinator.runningWork.isEmpty)
        FileTransferCoordinator.release(reservation)   // safe twice
        XCTAssertEqual(band.shown.count, 1)
    }

    /// S1: the early card covered by another notice: Esc is not taken and
    /// the transfer is not stopped (the Esc keeps its normal meaning).
    func testEscWithTheEarlyCardCoveredDoesNotStopTheTransfer() {
        let reservation = coordinator.reserveShowingProgress(.move, total: 3)
        band.replaceWithNotice()
        XCTAssertFalse(coordinator.cancelRunning(), "Esc goes on to its normal meaning")
        XCTAssertFalse(reservation.stop.isStopped, "the move is not cancelled")
        FileTransferCoordinator.release(reservation)
    }

    func testEscOnTheEarlyCardStopsTheTransferAndRemovesTheCard() {
        let reservation = coordinator.reserveShowingProgress(.copy, total: 3)
        XCTAssertTrue(coordinator.cancelRunning(), "Esc is taken while the early card shows")
        XCTAssertTrue(reservation.stop.isStopped)
        XCTAssertNil(band.current)
        XCTAssertFalse(coordinator.cancelRunning(), "nothing left to cancel")
        FileTransferCoordinator.release(reservation)
    }

    func testOneCardAtATimeWhileAnotherIsUp() {
        let first = coordinator.reserveShowingProgress(.copy, total: 3)
        let second = coordinator.reserveShowingProgress(.copy, total: 4)
        XCTAssertEqual(band.shown, ["Copying 1 of 3…"], "the queued transfer does not cover the first card")
        FileTransferCoordinator.release(second)
        XCTAssertNotNil(band.current, "releasing the queued one keeps the first card")
        FileTransferCoordinator.release(first)
        XCTAssertNil(band.current)
    }

    private func photos(_ count: Int, in folder: URL) throws -> [ImageGroup] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = folder.appendingPathComponent("p\(index).jpg")
            try Data(repeating: UInt8(index), count: 64).write(to: url)
            return ImageGroup(primary: url)
        }
    }

    func testACardReplacedBeforeTheRunStartsComesBack() async throws {
        FileTransferCoordinator.progressDelay = .milliseconds(20)
        let groups = try photos(2, in: root.appendingPathComponent("Source", isDirectory: true))
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        _ = try photos(1, in: destination)   // p0.jpg clashes: the run waits on the question
        let band = band!
        coordinator.conflictResponder = { _ in
            let deadline = Date().addingTimeInterval(3)
            while band.shown.count < 2, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return .skip
        }
        let reservation = coordinator.reserveShowingProgress(.copy, total: 2)
        band.replaceWithNotice()
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { $0 })
        _ = await coordinator.run(.copy, groups, to: destination, ops: ops, reservation: reservation)
        XCTAssertEqual(band.shown, ["Copying 1 of 2…", "Copying 1 of 2…"],
                       "the run's own card shows when the early one was covered")
        XCTAssertFalse(coordinator.isShowingProgress)
    }

    func testBrowserShowsTheCardBeforeAnyWaitAndRemovesItAtTheEnd() async throws {
        FileTransferCoordinator.progressDelay = .seconds(60)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let groups = try photos(2, in: source)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: source)
        defer { browser.close() }
        await browser.listingTask?.value
        browser.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { $0 })
        browser.transfer(.copy, groups, to: destination)
        XCTAssertTrue(browser.transferNotice.isShowingProgress, "the card shows in the same turn")
        await browser.trashChain?.value
        XCTAssertFalse(browser.transferNotice.isShowingProgress, "completion removes the card")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
    }

    func testRunTakesOverTheSameCardAndRemovesItAtTheEnd() async throws {
        FileTransferCoordinator.progressDelay = .zero   // the timer would show a card at once
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var groups: [ImageGroup] = []
        for index in 0..<3 {
            let url = source.appendingPathComponent("p\(index).jpg")
            try Data(repeating: UInt8(index), count: 64).write(to: url)
            groups.append(ImageGroup(primary: url))
        }
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { $0 })
        let reservation = coordinator.reserveShowingProgress(.copy, total: groups.count)
        XCTAssertEqual(band.shown, ["Copying 1 of 3…"])
        let outcome = await coordinator.run(.copy, groups, to: destination, ops: ops, reservation: reservation)
        XCTAssertEqual(outcome.items.count, 3)
        XCTAssertEqual(band.shown, ["Copying 1 of 3…"], "the run never shows a second card")
        XCTAssertGreaterThan(band.updates, 0, "progress updates the same card in place")
        XCTAssertNil(band.current, "completion removes the card")
        XCTAssertFalse(coordinator.isShowingProgress)
        XCTAssertTrue(FileTransferCoordinator.runningWork.isEmpty)
    }
}

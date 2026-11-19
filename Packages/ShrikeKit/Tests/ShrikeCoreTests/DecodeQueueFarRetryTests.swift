//
//  DecodeQueueFarRetryTests.swift
//  ShrikeCoreTests
//
//  A far (±2) preload refused only because no discretionary slot was free is
//  started again when a slot frees: driven by the budget's slot-freed event,
//  no timer. Never after memory relief, never for a replaced list or a window
//  that moved on, and a dropped queue leaves nothing behind.
//

import XCTest
import CoreGraphics
import os
@testable import ShrikeCore

/// A source whose `loadProperties` waits for a gate, so a test fixes the order
/// between the decode task and a cancel. Counts how many callers entered.
final class PropertiesGate: Sendable {
    private struct State { var entered = 0; var open = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var entered: Int { state.withLock { $0.entered } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                s.entered += 1
                if s.open { return true }
                s.waiters.append(c); return false
            }
            if resumeNow { c.resume() }
        }
    }
    func open() {
        let all = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true; defer { s.waiters = [] }; return s.waiters
        }
        all.forEach { $0.resume() }
    }
}

struct GatedTestSource: ImageSource {
    let key: Int
    let gate: PropertiesGate
    var id: String { "test://\(key)" }
    static func == (a: GatedTestSource, b: GatedTestSource) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
    var displayName: String { "gated-\(key)" }
    var fileSize: Int64? { 0 }
    var mtime: Date? { nil }
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        try await TestImageSource(key: key, decodeDelayMS: 0).loadCGImage(maxPixelSize: maxPixelSize)
    }
    func loadProperties() async throws -> ImageProperties {
        await gate.wait()
        return try await TestImageSource(key: key, decodeDelayMS: 0).loadProperties()
    }
}

final class DecodeQueueFarRetryTests: XCTestCase {

    private func sources(_ keys: Range<Int>) -> [TestImageSource] {
        keys.map { TestImageSource(key: $0, decodeDelayMS: 0) }
    }

    private func eventually(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// A budget with `slots` discretionary slots, all taken by the test.
    private func fullBudget(slots: Int = 2) -> (ImageResourceBudget, ImageResourceOwner, [ImageWorkReservation]) {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 512 << 20, maximumDiscretionaryWorkCount: slots))
        let testOwner = ImageResourceOwner()
        let held = (0..<slots).map { _ in
            budget.tryReserve(bytes: 1, owner: testOwner, category: .thumbnail, priority: .nearby, policy: .bounded)!
        }
        return (budget, testOwner, held)
    }

    /// Waits until the far index was spawned and refused (not running, not cached).
    private func awaitRefused(_ q: DecodeQueue, index: Int, id: String) async -> Bool {
        await eventually {
            let spawned = await q.spawnedIndicesForTesting()
            let running = await q.inFlightIDs()
            let cached = await q.cachedIDs()
            return spawned.contains(index) && !running.contains(id) && !cached.contains(id)
        }
    }

    func testRefusedFarPreloadIsRetriedWhenASlotFrees() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)

        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused, "the far neighbour must first be refused")
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 1, "exactly one retry is armed")

        held[0].release()   // the slot-freed event; no step, no timer
        let done = await eventually { await q.cachedIDs().contains(list[2].id) }
        XCTAssertTrue(done, "the far neighbour must be prepared once a slot freed")
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0)
        let spawns = await q.spawnedIndicesForTesting().filter { $0 == 2 }.count
        XCTAssertEqual(spawns, 2, "refused once, retried once")
        withExtendedLifetime(held) {}
        await q.purge()
    }

    func testNoRetryAfterMemoryRelief() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)

        budget.requestOptionalRelief()
        // Synchronous check: the negative spawn-count asserts below rest on it
        // (they cannot wait for a Task that must not run).
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0, "relief must drop the retry at once")
        held[0].release()
        _ = await q.wantedIDs()   // barrier: the actor has seen the relief
        let cached = await q.cachedIDs()
        XCTAssertFalse(cached.contains(list[2].id))
        let spawns = await q.spawnedIndicesForTesting().filter { $0 == 2 }.count
        XCTAssertEqual(spawns, 1)
        withExtendedLifetime(held) {}
        await q.purge()
    }

    func testNoRetryAfterSystemPressure() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)

        budget.setPressureForTesting(.critical)
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0)
        held[0].release()
        _ = await q.wantedIDs()
        let spawns = await q.spawnedIndicesForTesting().filter { $0 == 2 }.count
        XCTAssertEqual(spawns, 1)
        withExtendedLifetime(held) {}
        await q.purge()
    }

    func testNoRetryForAReplacedList() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let old = sources(0..<6)
        await q.setNavigation(list: old, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: old[2].id)
        XCTAssertTrue(refused)

        // Two photos only: the new list has no far neighbour to arm.
        await q.setNavigation(list: sources(20..<22), currentIndex: 0)
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0)
        held[0].release()
        _ = await q.wantedIDs()
        let spawns = await q.spawnedIndicesForTesting().filter { $0 == 2 }.count
        XCTAssertEqual(spawns, 1, "no decode for the old list's index 2")
        let cached = await q.cachedIDs()
        XCTAssertFalse(cached.contains(old[2].id))
        withExtendedLifetime(held) {}
        await q.purge()
    }

    func testRetryForANeighbourThatLeftTheWindowIsDropped() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<10)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)

        // Far jump: index 2 is no longer wanted, so its retry is dropped at once.
        // (The window around 8 may arm retries of its own; none for index 2.)
        _ = try await q.jumpToEntry(index: 8)
        let wanted = await q.wantedIDs()
        XCTAssertFalse(wanted.contains(list[2].id))
        let armedAfterJump = await eventually { budget.pendingSlotRetryCount(owner: owner) <= 1 }
        XCTAssertTrue(armedAfterJump, "retries never outnumber the wanted far neighbours")
        held[0].release()
        held[1].release()
        _ = await q.wantedIDs()
        let spawns = await q.spawnedIndicesForTesting().filter { $0 == 2 }.count
        XCTAssertEqual(spawns, 1, "the stale retry must not start index 2 again")
        let cached = await q.cachedIDs()
        XCTAssertFalse(cached.contains(list[2].id))
        withExtendedLifetime(held) {}
        await q.purge()
    }

    /// The queue-side guards, called directly so no timing is involved. The
    /// queue sits in the refused state (wanted, not running, not cached), so
    /// the one call with matching arguments is the positive control.
    func testRetryHandlerIgnoresStaleGenerationEpochAndMovedWindow() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<10)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)
        let generation = await q.generation
        func spawns() async -> Int { await q.spawnedIndicesForTesting().count }

        let base = await spawns()
        await q.retryFarPreload(index: 2, id: list[2].id, generation: generation &- 1, epoch: 0)   // list replaced
        await q.retryFarPreload(index: 2, id: list[2].id, generation: generation, epoch: -1)       // relief since arming
        await q.retryFarPreload(index: 2, id: list[3].id, generation: generation, epoch: 0)        // wrong file at index
        await q.retryFarPreload(index: 9, id: list[9].id, generation: generation, epoch: 0)        // not a wanted neighbour
        let afterStale = await spawns()
        XCTAssertEqual(afterStale, base, "stale retries must not start anything")

        await q.retryFarPreload(index: 2, id: list[2].id, generation: generation, epoch: 0)
        let afterControl = await spawns()
        XCTAssertEqual(afterControl, base + 1, "control: the matching retry does start the decode")
        withExtendedLifetime(held) {}
        await q.purge()
    }

    /// A slot can free before the refused decode's completion reaches the actor:
    /// the refused entry is still in `inFlight`. Run in one actor turn, so the
    /// order is fixed, with no timing.
    func testRetryReplacesTheRefusedDecodeStillInFlight() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)
        let started = await q.spawnThenRetryInOneTurnForTesting(index: 2)
        XCTAssertEqual(started, 2, "the refused decode is replaced by the retry")
        held[0].release()
        let done = await eventually { await q.cachedIDs().contains(list[2].id) }
        XCTAssertTrue(done)
        withExtendedLifetime(held) {}
        await q.purge()
    }

    /// A different live decode for the same file still blocks the retry.
    func testRetryWithAnotherDecodesTokenDoesNotReplaceTheLiveOne() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)
        let started = await q.spawnThenRetryInOneTurnForTesting(index: 2, tokenOffset: 1)
        XCTAssertEqual(started, 1, "only the spawn itself; the live decode is not replaced")
        withExtendedLifetime(held) {}
        await q.purge()
    }

    /// A decode cancelled while it estimated its size must not store a retry
    /// handler afterwards. The gate fixes the order; the task is the barrier.
    func testCancelledDecodeStoresNoRetry() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let gate = PropertiesGate()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        var list: [any ImageSource] = sources(0..<6)
        list[2] = GatedTestSource(key: 2, gate: gate)
        await q.setNavigation(list: list, currentIndex: 0)
        // Two callers wait on the gate: the header probe and the decode's size estimate.
        let entered = await eventually { gate.entered >= 2 }
        XCTAssertTrue(entered)
        let task = await q.inFlightTaskForTesting(id: list[2].id)
        XCTAssertNotNil(task)
        await q.purge()          // cancels the decode and clears retries
        gate.open()
        _ = try? await task?.value
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0, "a cancelled decode must not arm a retry")
        withExtendedLifetime(held) {}
    }

    func testNoRetryWhenBytesNotSlotsRefused() async throws {
        // Slots are free, bytes are not: waiting for a slot would not help.
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 1, maximumDiscretionaryWorkCount: 8))
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0)
        await q.purge()
    }

    func testDroppedQueueLeavesNoRetryAndDeallocates() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        weak var weakQueue: DecodeQueue?
        do {
            let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
            weakQueue = q
            let list = sources(0..<6)
            await q.setNavigation(list: list, currentIndex: 0)
            let refused = await awaitRefused(q, index: 2, id: list[2].id)
            XCTAssertTrue(refused)
            XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 1)
        }   // dropped without purge()
        let gone = await eventually { weakQueue == nil }
        XCTAssertTrue(gone, "a pending retry must not keep the queue alive")
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0, "deinit clears the retry")
        withExtendedLifetime(held) {}
    }

    func testPurgeClearsPendingRetry() async throws {
        let (budget, _, held) = fullBudget()
        let owner = ImageResourceOwner()
        let q = DecodeQueue(idleTrimDelay: nil, resources: budget, resourceOwner: owner)
        let list = sources(0..<6)
        await q.setNavigation(list: list, currentIndex: 0)
        let refused = await awaitRefused(q, index: 2, id: list[2].id)
        XCTAssertTrue(refused)
        await q.purge()
        XCTAssertEqual(budget.pendingSlotRetryCount(owner: owner), 0)
        held[0].release()
        _ = await q.wantedIDs()
        let cached = await q.cachedIDs()
        XCTAssertTrue(cached.isEmpty)
        withExtendedLifetime(held) {}
    }
}

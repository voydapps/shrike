import XCTest
import CoreGraphics
import os
@testable import ShrikeCore

final class ImageResourceBudgetTests: XCTestCase {
    private func budget(_ bytes: Int = 100) -> ImageResourceBudget {
        ImageResourceBudget(configuration: .init(normalBudget: bytes, maximumDiscretionaryWorkCount: 4))
    }
    private func waitForWaiters(_ count: Int, _ b: ImageResourceBudget) async throws {
        let deadline = Date().addingTimeInterval(2)
        while b.snapshot().pendingWaiterCount != count, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(b.snapshot().pendingWaiterCount, count)
    }
    /// Audit MP-05: the production cap must not sit below the thumbnail
    /// decode slots (each thumbnail job holds one reservation).
    func testDefaultDiscretionaryLimitCoversThumbnailDecodeSlots() {
        let cap = ImageResourceBudget.Configuration().maximumDiscretionaryWorkCount
        XCTAssertGreaterThanOrEqual(cap, ThumbnailCache.defaultMaxConcurrentDecodes)
    }

    func testWeightedAdmissionCancellationAndRelease() async throws {
        let b = budget(), owner = ImageResourceOwner()
        let a = try await b.reserve(bytes: 45, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
        let c = try await b.reserve(bytes: 45, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
        let blocked = Task { try await b.reserve(bytes: 20, owner: owner, category: .batchWork, priority: .batch, policy: .bounded) }
        try await waitForWaiters(1, b)
        blocked.cancel()
        do { _ = try await blocked.value; XCTFail("cancelled reservation must throw") } catch is CancellationError {}
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 90)
        a.release(); a.release(); c.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
    }
    func testSingleOversizedMakesProgressWithRetainedCurrentImage() async throws {
        let b = budget(), owner = ImageResourceOwner(), object = NSObject()
        let lease = b.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 90)], owner: owner, category: .editOriginal)
        let large = try await b.reserve(bytes: 200, owner: owner, category: .batchWork, priority: .batch, policy: .oneOversizedOperation)
        XCTAssertEqual(b.snapshot().activeOversizeOperationCount, 1)
        let next = Task { try await b.reserve(bytes: 5, owner: owner, category: .batchWork, priority: .batch, policy: .oneOversizedOperation) }
        try await waitForWaiters(1, b)
        XCTAssertNil(b.tryReserve(bytes: 1, owner: owner, category: .thumbnail, priority: .speculative, policy: .bounded))
        large.release()
        let small = try await next.value
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 5)
        small.release(); lease.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
    }
    private func waitForReservedBytes(_ bytes: Int, _ b: ImageResourceBudget) async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while b.snapshot().reservedEstimatedBytes != bytes, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, bytes)
        return b.snapshot().reservedEstimatedBytes == bytes
    }
    func testOversizedExportBypassesSaturatedNearbyWaiter() async throws {
        let b = budget(), owner = ImageResourceOwner(), object = NSObject()
        let retained = b.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                owner: owner, category: .editOriginal)
        let nearby = Task {
            try await b.reserve(bytes: 1, owner: owner, category: .thumbnail, priority: .nearby, policy: .bounded)
        }
        defer { nearby.cancel(); retained.release() }
        try await waitForWaiters(1, b)
        let export = Task {
            try await b.reserve(bytes: 200, owner: owner, category: .exportWork,
                                priority: .batch, policy: .oneOversizedOperation)
        }
        defer { export.cancel() }
        guard try await waitForReservedBytes(200, b) else { return }
        let token = try await export.value
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 1)
        XCTAssertEqual(b.snapshot().activeOversizeOperationCount, 1)
        XCTAssertNil(b.tryReserve(bytes: 200, owner: owner, category: .exportWork,
                                  priority: .visible, policy: .oneOversizedOperation))
        token.release()
        let synchronous = try XCTUnwrap(b.tryReserve(bytes: 200, owner: owner, category: .exportWork,
                                                    priority: .batch, policy: .oneOversizedOperation))
        synchronous.release()
        nearby.cancel(); _ = try? await nearby.value
        retained.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 0)
    }
    func testPumpingOversizedWorkBypassesPromotedBoundedWaiterAndPreservesFIFO() async throws {
        let b = budget(), owner = ImageResourceOwner(), object = NSObject(), nearbyID = UUID()
        let active = try await b.reserve(bytes: 100, owner: owner, category: .batchWork,
                                         priority: .batch, policy: .bounded)
        let retained = b.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                owner: owner, category: .editOriginal)
        let nearby = Task {
            try await b.reserve(bytes: 1, owner: owner, category: .thumbnail, priority: .nearby,
                                policy: .bounded, requestID: nearbyID)
        }
        defer { nearby.cancel(); active.release(); retained.release() }
        try await waitForWaiters(1, b)
        b.updatePriority(for: nearbyID, to: .visible)
        let first = Task {
            try await b.reserve(bytes: 200, owner: owner, category: .editPreview,
                                priority: .visible, policy: .oneOversizedOperation)
        }
        defer { first.cancel() }
        try await waitForWaiters(2, b)
        let second = Task {
            try await b.reserve(bytes: 300, owner: owner, category: .editPreview,
                                priority: .visible, policy: .oneOversizedOperation)
        }
        defer { second.cancel() }
        try await waitForWaiters(3, b)
        active.release()
        guard try await waitForReservedBytes(200, b) else { return }
        let firstToken = try await first.value
        XCTAssertEqual(b.snapshot().activeDiscretionaryOperationCount, 1)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 2)
        firstToken.release()
        guard try await waitForReservedBytes(300, b) else { return }
        let secondToken = try await second.value
        XCTAssertEqual(b.snapshot().activeOversizeOperationCount, 1)
        secondToken.release()
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 1)
        nearby.cancel(); _ = try? await nearby.value
        retained.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 0)
    }
    func testDeduplicatedResourceLifetimesAndCategories() {
        let b = budget(), object = NSObject(), a = ImageResourceOwner(), c = ImageResourceOwner()
        let cost = ImageResourceCost(identity: .init(object: object, kind: .gpuTexture), bytes: 80)
        let cache = b.retain([cost], owner: a, category: .displayCache)
        let view = b.retain([cost], owner: c, category: .fullResolution)
        XCTAssertEqual(b.snapshot().uniqueRetainedBytes, 80)
        XCTAssertEqual(b.snapshot().bytesByCategory.values.reduce(0, +), 80)
        cache.release(); XCTAssertEqual(b.snapshot().uniqueRetainedBytes, 80)
        view.release(); XCTAssertEqual(b.snapshot().uniqueRetainedBytes, 0)
    }
    func testCriticalPressureAndRequiredImageAreExplicit() async throws {
        let b = budget(), owner = ImageResourceOwner()
        b.setPressureForTesting(.critical)
        XCTAssertEqual(b.snapshot().effectiveTarget, 25)
        XCTAssertNil(b.tryReserve(bytes: 1, owner: owner, category: .decodeWork, priority: .speculative, policy: .bounded))
        let needed = try await b.reserve(bytes: 40, owner: owner, category: .decodeWork, priority: .visible, policy: .requiredImage)
        XCTAssertGreaterThan(b.snapshot().requiredImageOverage, 0)
        needed.release(); b.setPressureForTesting(.normal)
        XCTAssertEqual(b.snapshot().effectiveTarget, 100)
    }
    func testPriorityAndFIFOWithPromotion() async throws {
        let b = budget(), owner = ImageResourceOwner(), order = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let held = try await b.reserve(bytes: 100, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
        let prefetchID = UUID()
        let first = Task {
            let token = try await b.reserve(bytes: 100, owner: owner, category: .thumbnail, priority: .speculative,
                                            policy: .bounded, requestID: prefetchID)
            order.withLock { $0.append(1) }; token.release()
        }
        try await waitForWaiters(1, b)
        let second = Task {
            let token = try await b.reserve(bytes: 100, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
            order.withLock { $0.append(2) }; token.release()
        }
        try await waitForWaiters(2, b)
        b.updatePriority(for: prefetchID, to: .visible)
        held.release(); try await first.value; try await second.value
        XCTAssertEqual(order.withLock { $0 }, [1, 2])
    }
    func testAlreadyCancelledAndAdmissionRacesLeaveNoCapacity() async throws {
        let b = budget(), owner = ImageResourceOwner()
        for _ in 0..<50 {
            let task = Task {
                let token = try await b.reserve(bytes: 1, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
                token.release()
            }
            task.cancel(); _ = try? await task.value
        }
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 0)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 0)
    }
    func testCheckedWorkingSetRejectsInvalidAndOverflowDimensions() throws {
        XCTAssertThrowsError(try ImageWorkingSetEstimate(width: .max, height: 10))
        XCTAssertThrowsError(try ImageWorkingSetEstimate(width: 0, height: 10))
        let sdr = try ImageWorkingSetEstimate(width: 100, height: 100)
        let hdr = try ImageWorkingSetEstimate(width: 100, height: 100, bitsPerComponent: 16)
        XCTAssertEqual(sdr.totalBytes, 200_000)
        XCTAssertEqual(hdr.totalBytes, 400_000)
    }
    func testCancelledInterruptibleWaiterDoesNotReleaseRealWorkReservation() async throws {
        let b = budget(), owner = ImageResourceOwner(), started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0), lane = DecodeLane(width: 1)
        let task = Task {
            let token = try await b.reserve(bytes: 80, owner: owner, category: .decodeWork, priority: .visible, policy: .requiredImage)
            return try await lane.runInterruptible { _ in
                defer { withExtendedLifetime(token) {} }
                started.withLock { $0 = true }; release.wait(); return 1
            }
        }
        let startDeadline = Date().addingTimeInterval(30)
        while !started.withLock({ $0 }) {
            guard Date() < startDeadline else { release.signal(); return XCTFail("the gated work never started") }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled wait must throw") } catch is CancellationError {}
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 80)
        release.signal()
        _ = try await lane.run { 0 }
        let deadline = Date().addingTimeInterval(2)
        while b.snapshot().reservedEstimatedBytes > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 0)
    }
    func testOwnedLazyPixelsChargeOnReadAndSurviveQueueLeaseUntilProviderRelease() throws {
        let b = budget(1 << 20), owner = ImageResourceOwner()
        try autoreleasepool {
            let original = OrientedImageFixtures.quadrants(width: 32, height: 24)
            var image: CGImage? = try XCTUnwrap(LazyOrientedPixels.makeImage(width: 32, height: 24,
                space: CGColorSpaceCreateDeviceRGB(), decode: { original }))
            var lease: ImageResourceLease? = b.retain(image: try XCTUnwrap(image), owner: owner,
                                                      category: .displayCache, isLazy: true)
            XCTAssertNotNil(lease)
            XCTAssertEqual(b.snapshot().uniqueRetainedBytes, 0)
            var provider: CGDataProvider? = image?.dataProvider
            XCTAssertNotNil(provider)
            var ctx: CGContext? = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx?.draw(try XCTUnwrap(image), in: CGRect(x: 0, y: 0, width: 32, height: 24))
            XCTAssertGreaterThan(b.snapshot().uniqueRetainedBytes, 0)
            XCTAssertEqual(b.snapshot().conservativeRetainedBytes, 0)
            lease = nil; image = nil; ctx = nil
            XCTAssertGreaterThan(b.snapshot().uniqueRetainedBytes, 0, "provider still owns materialized pixels")
            provider = nil
        }
        XCTAssertEqual(b.snapshot().uniqueRetainedBytes, 0, "last provider release must free the actual CPU charge")
    }
    func testUnobservableLazyProviderUsesExplicitConservativeCharge() {
        let b = budget(1 << 20), image = OrientedImageFixtures.quadrants(width: 16, height: 16)
        let token = b.retain(image: image, owner: .init(), category: .fullResolution, isLazy: true)
        XCTAssertGreaterThan(b.snapshot().conservativeRetainedBytes, 0)
        XCTAssertEqual(b.snapshot().conservativeRetainedBytes, b.snapshot().uniqueRetainedBytes)
        token.release(); XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
    }
    func testFittingOversizedPolicyAndMissingPriorityUpdatesDoNotRequestRelief() async throws {
        let b = budget(), owner = ImageResourceOwner(), warnings = OSAllocatedUnfairLock(initialState: 0)
        let observation = b.observePressure { _ in _ = b.snapshot(); warnings.withLock { $0 += 1 } }
        defer { observation.cancel() }
        let synchronous = try XCTUnwrap(b.tryReserve(bytes: 10, owner: owner, category: .thumbnail,
                                                     priority: .visible, policy: .oneOversizedOperation))
        synchronous.release()
        let asynchronous = try await b.reserve(bytes: 10, owner: owner, category: .exportWork,
                                               priority: .batch, policy: .oneOversizedOperation)
        asynchronous.release()
        for _ in 0..<3 { b.updatePriority(for: UUID(), to: .visible, policy: .oneOversizedOperation) }
        XCTAssertEqual(warnings.withLock { $0 }, 0)
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
    }
    func testCountContentionAndRepeatedUnchangedPriorityDoNotRequestRelief() async throws {
        let b = ImageResourceBudget(configuration: .init(normalBudget: 100, maximumDiscretionaryWorkCount: 1))
        let owner = ImageResourceOwner(), warnings = OSAllocatedUnfairLock(initialState: 0), id = UUID()
        let observation = b.observePressure { _ in warnings.withLock { $0 += 1 } }
        defer { observation.cancel() }
        let held = try await b.reserve(bytes: 10, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
        defer { held.release() }
        let waiting = Task {
            try await b.reserve(bytes: 10, owner: owner, category: .thumbnail, priority: .visible,
                                policy: .oneOversizedOperation, requestID: id)
        }
        try await waitForWaiters(1, b)
        for _ in 0..<3 { b.updatePriority(for: id, to: .visible, policy: .oneOversizedOperation) }
        XCTAssertNil(b.tryReserve(bytes: 10, owner: owner, category: .thumbnail,
                                  priority: .visible, policy: .oneOversizedOperation))
        XCTAssertEqual(warnings.withLock { $0 }, 0, "operation-count contention is not a byte shortage")
        waiting.cancel(); _ = try? await waiting.value
        held.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 0)
    }
    func testRealOversizedPromotionRequestsFiniteReliefAndStillMakesProgress() async throws {
        let b = budget(), owner = ImageResourceOwner(), object = NSObject(), id = UUID()
        let retained = b.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                owner: owner, category: .editOriginal)
        defer { retained.release() }
        let warnings = OSAllocatedUnfairLock(initialState: 0)
        let observation = b.observePressure { _ in _ = b.snapshot(); warnings.withLock { $0 += 1 } }
        defer { observation.cancel() }
        let waiting = Task {
            try await b.reserve(bytes: 20, owner: owner, category: .thumbnail, priority: .nearby,
                                policy: .bounded, requestID: id)
        }
        defer { waiting.cancel() }
        try await waitForWaiters(1, b)
        b.updatePriority(for: id, to: .visible, policy: .oneOversizedOperation)
        guard try await waitForReservedBytes(20, b) else { return }
        let promoted = try await waiting.value
        for _ in 0..<3 { b.updatePriority(for: id, to: .visible, policy: .oneOversizedOperation) }
        XCTAssertEqual(warnings.withLock { $0 }, 1)
        XCTAssertEqual(b.snapshot().activeOversizeOperationCount, 1)
        XCTAssertNil(b.tryReserve(bytes: 200, owner: owner, category: .exportWork,
                                  priority: .visible, policy: .oneOversizedOperation))
        XCTAssertEqual(warnings.withLock { $0 }, 1, "a rejected concurrent exception must not fan out more relief")
        promoted.release()
        let synchronous = try XCTUnwrap(b.tryReserve(bytes: 200, owner: owner, category: .exportWork,
                                                    priority: .visible, policy: .oneOversizedOperation))
        XCTAssertEqual(warnings.withLock { $0 }, 2, "actual new oversized work still requests relief")
        synchronous.release()
        XCTAssertEqual(b.snapshot().reservedEstimatedBytes, 0)
    }
    func testQueuedRequestBecomingOversizedStillRequestsReliefBeforeWorkResumes() async throws {
        let b = ImageResourceBudget(configuration: .init(normalBudget: 100, maximumDiscretionaryWorkCount: 1))
        let owner = ImageResourceOwner(), object = NSObject(), warnings = OSAllocatedUnfairLock(initialState: 0)
        let observation = b.observePressure { _ in _ = b.snapshot(); warnings.withLock { $0 += 1 } }
        defer { observation.cancel() }
        let held = try await b.reserve(bytes: 10, owner: owner, category: .batchWork, priority: .batch, policy: .bounded)
        let waiting = Task {
            try await b.reserve(bytes: 20, owner: owner, category: .exportWork, priority: .batch, policy: .oneOversizedOperation)
        }
        defer { waiting.cancel(); held.release() }
        try await waitForWaiters(1, b)
        XCTAssertEqual(warnings.withLock { $0 }, 0)
        let retained = b.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 90)],
                                owner: owner, category: .editOriginal)
        defer { retained.release() }
        XCTAssertEqual(warnings.withLock { $0 }, 0, "actual charged bytes are exactly at target")
        held.release()
        guard try await waitForReservedBytes(20, b) else { return }
        let token = try await waiting.value
        XCTAssertEqual(warnings.withLock { $0 }, 1, "the now-oversized grant must request relief before returning")
        XCTAssertEqual(b.snapshot().activeOversizeOperationCount, 1)
        token.release(); retained.release()
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
    }
    func testCancellationDuringReliefPassLeavesNoRegistrationOrReservation() async throws {
        let b = budget(), owner = ImageResourceOwner()
        let observation = b.observePressure { _ in withUnsafeCurrentTask { $0?.cancel() } }
        defer { observation.cancel() }
        let task = Task {
            try await b.reserve(bytes: 200, owner: owner, category: .exportWork, priority: .batch, policy: .oneOversizedOperation)
        }
        do { _ = try await task.value; XCTFail("relief cancellation must throw") } catch is CancellationError {}
        XCTAssertEqual(b.snapshot().aggregateChargedBytes, 0)
        XCTAssertEqual(b.snapshot().pendingWaiterCount, 0)
    }
    func testPressureCallbacksRunOutsideBudgetLock() {
        let b = budget(), seen = OSAllocatedUnfairLock(initialState: false)
        let observation = b.observePressure { _ in _ = b.snapshot(); seen.withLock { $0 = true } }
        b.setPressureForTesting(.warning)
        XCTAssertTrue(seen.withLock { $0 }); observation.cancel()
    }
}

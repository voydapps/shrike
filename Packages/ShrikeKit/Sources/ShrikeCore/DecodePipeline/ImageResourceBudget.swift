import Foundation
import os

public struct ImageResourceOwner: Hashable, Sendable {
    private let id = UUID()
    public init() {}
}
public enum ImageResourceKind: String, Hashable, Sendable { case cpuPixels, gpuTexture }
public struct ImageResourceIdentity: Hashable, Sendable {
    private let object: ObjectIdentifier
    private let kind: ImageResourceKind
    public init(object: AnyObject, kind: ImageResourceKind) { self.object = ObjectIdentifier(object); self.kind = kind }
}
public struct ImageResourceCost: Sendable {
    public let identity: ImageResourceIdentity
    public let bytes: Int
    public let isConservativeEstimate: Bool
    public init(identity: ImageResourceIdentity, bytes: Int, isConservativeEstimate: Bool = false) {
        self.identity = identity; self.bytes = max(0, bytes); self.isConservativeEstimate = isConservativeEstimate
    }
}
public enum ImageResourceCategory: String, Hashable, Sendable {
    case displayCache, fullResolution, editOriginal, editPreview, thumbnail, decodeWork, batchWork, exportWork
}
public enum ImageWorkPriority: Int, Sendable { case speculative, batch, nearby, visible }
public enum ImageAdmissionPolicy: Sendable, Equatable { case bounded, requiredImage, oneOversizedOperation }
public enum ImageMemoryPressure: Sendable, Equatable { case normal, warning, critical }
public enum ImageResourceError: Error, Sendable { case invalidByteCount, dimensionOverflow }

/// Mutable admission intent for a thumbnail shared by callers. The budget
/// reads it while inserting its waiter, closing the pre-enqueue promotion gap.
internal final class ImageWorkDemand: Sendable {
    private let value: OSAllocatedUnfairLock<(priority: ImageWorkPriority, policy: ImageAdmissionPolicy)>
    init(priority: ImageWorkPriority, policy: ImageAdmissionPolicy) {
        value = OSAllocatedUnfairLock(initialState: (priority, policy))
    }
    func update(priority: ImageWorkPriority, policy: ImageAdmissionPolicy) {
        value.withLock { $0 = (priority, policy) }
    }
    func snapshot() -> (priority: ImageWorkPriority, policy: ImageAdmissionPolicy) { value.withLock { $0 } }
}

public struct ImageResourceSnapshot: Sendable {
    public let normalTarget: Int
    public let effectiveTarget: Int
    public let pressure: ImageMemoryPressure
    public let uniqueRetainedBytes: Int
    public let conservativeRetainedBytes: Int
    public let reservedEstimatedBytes: Int
    public let aggregateChargedBytes: Int
    /// Unique resource bytes attributed to the alphabetically first live
    /// category; reservations to their sole category. No duplicate labels.
    public let bytesByCategory: [ImageResourceCategory: Int]
    public let pendingWaiterCount: Int
    public let activeDiscretionaryOperationCount: Int
    public let aggregateOverageBytes: Int
    /// Compatibility name for aggregate overage, not an attribution to
    /// required-image owners. Retained categories cannot prove necessity.
    public let requiredImageOverage: Int
    public let activeOversizeOperationCount: Int
}

public final class ImageWorkReservation: Sendable {
    private let budget: ImageResourceBudget
    private let id: UUID
    private let released = OSAllocatedUnfairLock(initialState: false)
    fileprivate init(_ budget: ImageResourceBudget, _ id: UUID) { self.budget = budget; self.id = id }
    public func release() {
        if released.withLock({ value in if value { return false }; value = true; return true }) { budget.releaseWork(id) }
    }
    deinit { release() }
}
public final class ImageResourceLease: Sendable {
    private let budget: ImageResourceBudget
    private let id: UUID
    private let released = OSAllocatedUnfairLock(initialState: false)
    fileprivate init(_ budget: ImageResourceBudget, _ id: UUID) { self.budget = budget; self.id = id }
    public func release() {
        if released.withLock({ value in if value { return false }; value = true; return true }) { budget.releaseLease(id) }
    }
    deinit { release() }
}
public final class ImagePressureObservation: Sendable {
    private let budget: ImageResourceBudget
    private let id: UUID
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    fileprivate init(_ budget: ImageResourceBudget, _ id: UUID) { self.budget = budget; self.id = id }
    public func cancel() {
        if cancelled.withLock({ value in if value { return false }; value = true; return true }) { budget.removeObserver(id) }
    }
    deinit { cancel() }
}

/// One process-wide accounting/admission authority. This bounds managed
/// discretionary payloads, not Metal drawables or total process footprint.
public final class ImageResourceBudget: Sendable {
    /// How many discretionary jobs may run at once. At least as many as the
    /// thumbnail decode slots: every thumbnail job holds one reservation, so
    /// a lower cap silently throttled them (measured 2026-10-24, audit MP-05:
    /// cap 3 with 4 slots 53/s vs 69/s; cap 6 with 8 slots 99/s vs 119/s).
    /// On macOS 14 decodes run on the cooperative pool, so one core stays free.
    public static var defaultDiscretionaryWorkLimit: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if #available(macOS 15.0, *) { return max(2, min(cores, 8)) }
        return max(2, min(cores - 1, 6))
    }

    public struct Configuration: Sendable {
        public var normalBudget: Int
        public var warningMultiplier: Double
        public var criticalMultiplier: Double
        public var maximumDiscretionaryWorkCount: Int
        public var monitorSystemPressure: Bool
        public init(normalBudget: Int? = nil, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                    warningMultiplier: Double = 0.5, criticalMultiplier: Double = 0.25,
                    maximumDiscretionaryWorkCount: Int = ImageResourceBudget.defaultDiscretionaryWorkLimit,
                    monitorSystemPressure: Bool = false) {
            self.normalBudget = max(1, normalBudget ?? min(640 << 20, max(192 << 20, Int(clamping: physicalMemory / 8))))
            self.warningMultiplier = warningMultiplier.isFinite ? min(1, max(0.01, warningMultiplier)) : 0.5
            self.criticalMultiplier = criticalMultiplier.isFinite ? min(1, max(0.01, criticalMultiplier)) : 0.25
            self.maximumDiscretionaryWorkCount = max(1, maximumDiscretionaryWorkCount)
            self.monitorSystemPressure = monitorSystemPressure
        }
    }
    public static let shared = ImageResourceBudget(configuration: .init(monitorSystemPressure: true))
    private struct Resource: Sendable {
        var bytes: Int
        var conservative: Bool
        var holders: [UUID: (ImageResourceOwner, ImageResourceCategory)]
    }
    private struct Work: Sendable {
        let bytes: Int
        let owner: ImageResourceOwner
        let category: ImageResourceCategory
        let policy: ImageAdmissionPolicy
        let oversize: Bool
    }
    private struct Waiter: Sendable {
        let id: UUID
        let bytes: Int
        let owner: ImageResourceOwner
        let category: ImageResourceCategory
        var priority: ImageWorkPriority
        var policy: ImageAdmissionPolicy
        var reliefRequested: Bool
        let continuation: CheckedContinuation<ImageWorkReservation, any Error>
    }
    private struct State: Sendable {
        var resources: [ImageResourceIdentity: Resource] = [:]
        var leases: [UUID: [ImageResourceIdentity]] = [:]
        var work: [UUID: Work] = [:]
        var waiters: [Waiter] = []
        var cancelled: Set<UUID> = []
        var registrations: Set<UUID> = []
        var observers: [UUID: @Sendable (ImageMemoryPressure) -> Void] = [:]
        var pressure: ImageMemoryPressure = .normal
    }
    private let configuration: Configuration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pressureSource = OSAllocatedUnfairLock<(any DispatchSourceMemoryPressure)?>(initialState: nil)
    private let profileSource = OSAllocatedUnfairLock<(any DispatchSourceTimer)?>(initialState: nil)
    private static let profileLog = Logger(subsystem: "app.shrike", category: "imageResources")
    public init(configuration: Configuration) {
        self.configuration = configuration
        if ProcessInfo.processInfo.environment["SHRIKE_RESOURCE_PROFILE"] == "1" {
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let s = self.snapshot()
                let categories = s.bytesByCategory.keys.sorted { $0.rawValue < $1.rawValue }
                    .map { "\($0.rawValue)=\(s.bytesByCategory[$0] ?? 0)" }.joined(separator: ",")
                let line = "target=\(s.normalTarget) effective=\(s.effectiveTarget) pressure=\(s.pressure) uniqueRetained=\(s.uniqueRetainedBytes) conservative=\(s.conservativeRetainedBytes) reserved=\(s.reservedEstimatedBytes) aggregate=\(s.aggregateChargedBytes) overage=\(s.aggregateOverageBytes) waiters=\(s.pendingWaiterCount) activeDiscretionary=\(s.activeDiscretionaryOperationCount) activeOversize=\(s.activeOversizeOperationCount) categories=[\(categories)]"
                Self.profileLog.notice("\(line, privacy: .public)")
            }
            profileSource.withLock { $0 = source }
            source.resume()
        }
        if configuration.monitorSystemPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                guard let self, let data = self.pressureSource.withLock({ $0?.data }) else { return }
                let events = DispatchSource.MemoryPressureEvent(rawValue: data)
                self.setPressure(events.contains(.critical) ? .critical : events.contains(.warning) ? .warning : .normal)
            }
            pressureSource.withLock { $0 = source }
            source.resume()
        }
    }
    deinit {
        pressureSource.withLock { $0 }?.cancel()
        profileSource.withLock { $0 }?.cancel()
    }
    private func target(_ s: State) -> Int {
        let multiplier = s.pressure == .critical ? configuration.criticalMultiplier
            : s.pressure == .warning ? configuration.warningMultiplier : 1
        if multiplier >= 1 { return configuration.normalBudget }
        return max(1, Int(Double(configuration.normalBudget) * multiplier))
    }
    private static func plus(_ a: Int, _ b: Int) -> Int { let (v, overflow) = a.addingReportingOverflow(b); return overflow ? .max : v }
    private func totals(_ s: State) -> (retained: Int, reserved: Int) {
        (s.resources.values.reduce(0) { Self.plus($0, $1.bytes) }, s.work.values.reduce(0) { Self.plus($0, $1.bytes) })
    }
    private func canAdmit(_ bytes: Int, _ policy: ImageAdmissionPolicy, _ priority: ImageWorkPriority, _ s: State) -> Bool {
        if policy == .requiredImage { return true }
        let discretionary = s.work.values.filter { $0.policy != .requiredImage }
        if s.pressure == .critical, priority == .speculative { return false }
        if discretionary.contains(where: \.oversize) { return false }
        let limit = s.pressure == .critical ? 1 : configuration.maximumDiscretionaryWorkCount
        if discretionary.count >= limit { return false }
        let current = totals(s)
        let fits = Self.plus(Self.plus(current.retained, current.reserved), bytes) <= target(s)
        return fits || (policy == .oneOversizedOperation && discretionary.isEmpty)
    }
    private func exceedsTarget(adding bytes: Int, _ s: State) -> Bool {
        let current = totals(s)
        return Self.plus(Self.plus(current.retained, current.reserved), bytes) > target(s)
    }
    private func usesOversizeException(_ bytes: Int, _ policy: ImageAdmissionPolicy, _ s: State) -> Bool {
        guard policy == .oneOversizedOperation,
              !s.work.values.contains(where: { $0.policy != .requiredImage }) else { return false }
        let current = totals(s)
        return Self.plus(Self.plus(current.retained, current.reserved), bytes) > target(s)
    }
    private func nextWaiterIndex(_ s: State) -> Int? {
        let ordered = s.waiters.indices.sorted {
            let left = s.waiters[$0].priority.rawValue, right = s.waiters[$1].priority.rawValue
            return left == right ? $0 < $1 : left > right
        }
        guard let first = ordered.first else { return nil }
        let head = s.waiters[first]
        if canAdmit(head.bytes, head.policy, head.priority, s) { return first }
        // Retained current pixels may keep bounded optional work blocked
        // indefinitely. The sole oversize exception must still make progress;
        // eligible exceptions preserve priority/FIFO among themselves. Ordinary
        // bounded work never bypasses a blocked higher-priority/FIFO head.
        return ordered.first { index in
            let waiter = s.waiters[index]
            return usesOversizeException(waiter.bytes, waiter.policy, s)
                && canAdmit(waiter.bytes, waiter.policy, waiter.priority, s)
        }
    }
    private func hasBlockingWaiter(bytes: Int, priority: ImageWorkPriority,
                                   policy: ImageAdmissionPolicy, _ s: State) -> Bool {
        guard policy != .requiredImage else { return false }
        let predecessors = s.waiters.filter { $0.priority.rawValue >= priority.rawValue }
        if !usesOversizeException(bytes, policy, s) { return !predecessors.isEmpty }
        return predecessors.contains {
            canAdmit($0.bytes, $0.policy, $0.priority, s)
        }
    }
    private func install(_ id: UUID, bytes: Int, owner: ImageResourceOwner, category: ImageResourceCategory,
                         priority: ImageWorkPriority, policy: ImageAdmissionPolicy, _ s: inout State) {
        let current = totals(s)
        s.work[id] = Work(bytes: bytes, owner: owner, category: category, policy: policy,
                          oversize: policy != .requiredImage && Self.plus(Self.plus(current.retained, current.reserved), bytes) > target(s))
    }
    public func tryReserve(bytes: Int, owner: ImageResourceOwner, category: ImageResourceCategory,
                           priority: ImageWorkPriority, policy: ImageAdmissionPolicy) -> ImageWorkReservation? {
        guard bytes >= 0 else { return nil }
        let id = UUID()
        var reliefRequested = false
        while true {
            let requestedThisPass = reliefRequested
            let outcome = state.withLock { s -> Int in
                guard canAdmit(bytes, policy, priority, s),
                      !hasBlockingWaiter(bytes: bytes, priority: priority, policy: policy, s) else { return 0 }
                if policy == .oneOversizedOperation, exceedsTarget(adding: bytes, s), !requestedThisPass { return 2 }
                install(id, bytes: bytes, owner: owner, category: category, priority: priority, policy: policy, &s)
                return 1
            }
            if outcome == 2 { requestOptionalRelief(); reliefRequested = true; continue }
            return outcome == 1 ? ImageWorkReservation(self, id) : nil
        }
    }
    public func reserve(bytes: Int, owner: ImageResourceOwner, category: ImageResourceCategory,
                        priority: ImageWorkPriority, policy: ImageAdmissionPolicy,
                        requestID: UUID? = nil) async throws -> ImageWorkReservation {
        try await reserve(bytes: bytes, owner: owner, category: category, priority: priority,
                          policy: policy, requestID: requestID, demand: nil)
    }
    internal func reserve(bytes: Int, owner: ImageResourceOwner, category: ImageResourceCategory,
                          requestID: UUID, demand: ImageWorkDemand) async throws -> ImageWorkReservation {
        let current = demand.snapshot()
        return try await reserve(bytes: bytes, owner: owner, category: category, priority: current.priority,
                                 policy: current.policy, requestID: requestID, demand: demand)
    }
    private func reserve(bytes: Int, owner: ImageResourceOwner, category: ImageResourceCategory,
                         priority: ImageWorkPriority, policy: ImageAdmissionPolicy, requestID: UUID?,
                         demand: ImageWorkDemand?) async throws -> ImageWorkReservation {
        guard bytes >= 0 else { throw ImageResourceError.invalidByteCount }
        try Task.checkCancellation()
        var reliefRequested = false
        if policy == .oneOversizedOperation {
            if let fitting = tryReserve(bytes: bytes, owner: owner, category: category, priority: priority, policy: .bounded) {
                if Task.isCancelled { fitting.release(); throw CancellationError() }
                return fitting
            }
            if state.withLock({ exceedsTarget(adding: bytes, $0) }) {
                // Count/priority contention alone does not require global
                // relief. A real byte shortage gets one finite pass.
                requestOptionalRelief()
                reliefRequested = true
                await Task.yield()
            }
        }
        let id = requestID ?? UUID()
        state.withLock { _ = $0.registrations.insert(id) }
        let requestedBeforeInsertion = reliefRequested
        let reservation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ImageWorkReservation, any Error>) in
                var insertionReliefRequested = requestedBeforeInsertion
                while true {
                    let requestedThisPass = insertionReliefRequested
                    let outcome = state.withLock { s -> Int in
                        if s.cancelled.remove(id) != nil { s.registrations.remove(id); return -1 }
                        // Lock order: insertion owns budget then briefly demand;
                        // mutations release demand before entering budget update.
                        let current = demand?.snapshot()
                        let admittedPriority = current?.priority ?? priority
                        let admittedPolicy = current?.policy ?? policy
                        if admittedPolicy == .oneOversizedOperation, exceedsTarget(adding: bytes, s), !requestedThisPass {
                            // Keep cancellation registration live across the
                            // callback pass, then re-read the latest demand.
                            return 2
                        }
                        s.registrations.remove(id)
                        if canAdmit(bytes, admittedPolicy, admittedPriority, s),
                           !hasBlockingWaiter(bytes: bytes, priority: admittedPriority, policy: admittedPolicy, s) {
                            install(id, bytes: bytes, owner: owner, category: category, priority: admittedPriority, policy: admittedPolicy, &s)
                            return 1
                        }
                        s.waiters.append(Waiter(id: id, bytes: bytes, owner: owner, category: category, priority: admittedPriority,
                                                policy: admittedPolicy, reliefRequested: requestedThisPass, continuation: continuation))
                        return 0
                    }
                    if outcome == 2 { requestOptionalRelief(); insertionReliefRequested = true; continue }
                    if outcome < 0 { continuation.resume(throwing: CancellationError()) }
                    else if outcome > 0 { continuation.resume(returning: ImageWorkReservation(self, id)) }
                    else { pump() }
                    break
                }
            }
        } onCancel: { self.cancelWaiter(id) }
        if Task.isCancelled { reservation.release(); throw CancellationError() }
        return reservation
    }
    private func cancelWaiter(_ id: UUID) {
        let waiter = state.withLock { s -> Waiter? in
            if let index = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: index) }
            if s.registrations.contains(id) { s.cancelled.insert(id) }
            return nil
        }
        waiter?.continuation.resume(throwing: CancellationError())
        pump()
    }
    public func updatePriority(for requestID: UUID, to priority: ImageWorkPriority,
                               policy: ImageAdmissionPolicy? = nil) {
        let needsRelief = state.withLock { s -> Bool in
            guard let index = s.waiters.firstIndex(where: { $0.id == requestID }) else { return false }
            let previousPolicy = s.waiters[index].policy
            s.waiters[index].priority = priority
            if let policy {
                s.waiters[index].policy = policy
                if policy != .oneOversizedOperation { s.waiters[index].reliefRequested = false }
            }
            let needsRelief = policy == .oneOversizedOperation && previousPolicy != .oneOversizedOperation
                && exceedsTarget(adding: s.waiters[index].bytes, s)
            if needsRelief { s.waiters[index].reliefRequested = true }
            return needsRelief
        }
        if needsRelief { requestOptionalRelief() }
        pump()
    }
    private func pump() {
        let ready = state.withLock { s -> [(waiter: Waiter, needsRelief: Bool)] in
            var ready: [(waiter: Waiter, needsRelief: Bool)] = []
            while let index = nextWaiterIndex(s) {
                let w = s.waiters[index]
                s.waiters.remove(at: index)
                let needsRelief = usesOversizeException(w.bytes, w.policy, s) && !w.reliefRequested
                install(w.id, bytes: w.bytes, owner: w.owner, category: w.category, priority: w.priority, policy: w.policy, &s)
                ready.append((w, needsRelief))
            }
            return ready
        }
        if ready.contains(where: { $0.needsRelief }) { requestOptionalRelief() }
        for item in ready { item.waiter.continuation.resume(returning: ImageWorkReservation(self, item.waiter.id)) }
    }
    fileprivate func releaseWork(_ id: UUID) { state.withLock { _ = $0.work.removeValue(forKey: id) }; pump() }
    public func retain(_ costs: [ImageResourceCost], owner: ImageResourceOwner,
                       category: ImageResourceCategory) -> ImageResourceLease {
        let id = UUID()
        let callbacks = state.withLock { s -> [@Sendable (ImageMemoryPressure) -> Void] in
            let before = totals(s)
            for cost in costs {
                var resource = s.resources[cost.identity] ?? Resource(bytes: 0, conservative: false, holders: [:])
                resource.bytes = max(resource.bytes, cost.bytes)
                resource.conservative = resource.conservative || cost.isConservativeEstimate
                resource.holders[id] = (owner, category)
                s.resources[cost.identity] = resource
            }
            s.leases[id] = Array(Set(costs.map(\.identity)))
            let after = totals(s)
            return Self.plus(before.retained, before.reserved) <= target(s)
                && Self.plus(after.retained, after.reserved) > target(s) ? Array(s.observers.values) : []
        }
        for callback in callbacks { callback(.warning) }
        return ImageResourceLease(self, id)
    }
    fileprivate func releaseLease(_ id: UUID) {
        state.withLock { s in
            for identity in s.leases.removeValue(forKey: id) ?? [] {
                guard var resource = s.resources[identity] else { continue }
                resource.holders[id] = nil
                if resource.holders.isEmpty { s.resources[identity] = nil } else { s.resources[identity] = resource }
            }
        }
        pump()
    }
    public func observePressure(_ callback: @escaping @Sendable (ImageMemoryPressure) -> Void) -> ImagePressureObservation {
        let id = UUID(); state.withLock { $0.observers[id] = callback }; return ImagePressureObservation(self, id)
    }
    public func requestOptionalRelief() {
        let callbacks = state.withLock { Array($0.observers.values) }
        for callback in callbacks { callback(.warning) }
    }
    fileprivate func removeObserver(_ id: UUID) {
        let removed = state.withLock { $0.observers.removeValue(forKey: id) }
        withExtendedLifetime(removed) {}
    }
    public func setPressureForTesting(_ pressure: ImageMemoryPressure) { setPressure(pressure) }
    private func setPressure(_ pressure: ImageMemoryPressure) {
        let callbacks = state.withLock { s in s.pressure = pressure; return Array(s.observers.values) }
        for callback in callbacks { callback(pressure) }
        pump()
    }
    public func availableBytes(excluding owner: ImageResourceOwner? = nil) -> Int {
        state.withLock { s in
            let retained = s.resources.values.filter { resource in
                guard let owner else { return true }; return resource.holders.values.contains { $0.0 != owner }
            }.reduce(0) { Self.plus($0, $1.bytes) }
            let reserved = s.work.values.filter { $0.owner != owner }.reduce(0) { Self.plus($0, $1.bytes) }
            return max(0, target(s) - min(target(s), Self.plus(retained, reserved)))
        }
    }
    public func snapshot() -> ImageResourceSnapshot {
        state.withLock { s in
            let total = totals(s)
            var categories: [ImageResourceCategory: Int] = [:]
            for resource in s.resources.values {
                if let category = resource.holders.values.map(\.1).min(by: { $0.rawValue < $1.rawValue }) {
                    categories[category] = Self.plus(categories[category] ?? 0, resource.bytes)
                }
            }
            for work in s.work.values { categories[work.category] = Self.plus(categories[work.category] ?? 0, work.bytes) }
            let aggregate = Self.plus(total.retained, total.reserved)
            return ImageResourceSnapshot(normalTarget: configuration.normalBudget, effectiveTarget: target(s), pressure: s.pressure,
                uniqueRetainedBytes: total.retained,
                conservativeRetainedBytes: s.resources.values.filter(\.conservative).reduce(0) { Self.plus($0, $1.bytes) },
                reservedEstimatedBytes: total.reserved, aggregateChargedBytes: aggregate,
                bytesByCategory: categories, pendingWaiterCount: s.waiters.count,
                activeDiscretionaryOperationCount: s.work.values.filter { $0.policy != .requiredImage }.count,
                aggregateOverageBytes: max(0, aggregate - target(s)),
                requiredImageOverage: max(0, aggregate - target(s)), activeOversizeOperationCount: s.work.values.filter(\.oversize).count)
        }
    }
}

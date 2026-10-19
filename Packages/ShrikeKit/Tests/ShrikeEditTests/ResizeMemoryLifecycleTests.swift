import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os
import ShrikeCore
import ShrikeIO
@testable import ShrikeEdit

final class ResizeMemoryLifecycleTests: XCTestCase {
    private func until(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let ready = await condition()
        XCTAssertTrue(ready)
        return ready
    }
    private static func drain(_ stream: AsyncThrowingStream<BatchProgress, any Error>) async throws -> BatchResult {
        var result: BatchResult?
        for try await update in stream { if let final = update.result { result = final } }
        return try XCTUnwrap(result)
    }
    private func image() -> CGImage {
        EditFixture.solidRGB(width: 128, height: 64, red: 0.7, green: 0.2, blue: 0.5)
    }
    private func source(_ tmp: EditTempDir) throws -> URL {
        let url = tmp.url.appendingPathComponent("source.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func warmSharedContext() {
        _ = ResizeTool.apply(.init(width: 64, height: 32, interpolation: .lanczos, preventUpscale: false), to: image())
        XCTAssertTrue(ResizeTool.contexts.stateForTesting().hasContext)
    }

    func testNonLanczosAndNoOpBatchScopesNeverInitializeProcessingContext() {
        let constructions = OSAllocatedUnfairLock(initialState: 0), clears = OSAllocatedUnfairLock(initialState: 0)
        let relief = OSAllocatedUnfairLock(initialState: 0)
        let store = ResizeContextStore(makeContext: {
            constructions.withLock { $0 += 1 }
            return CIContext(options: [.cacheIntermediates: false])
        }, clearContext: { context in context.clearCaches(); clears.withLock { $0 += 1 } },
            relieveAllocator: { relief.withLock { $0 += 1 } })
        let scope = store.beginBatch(), input = image()
        for interpolation in [Interpolation.bicubic, .bilinear, .nearest] {
            let out = ResizeTool.apply(.init(width: 64, height: 32, interpolation: interpolation, preventUpscale: false), to: input, contexts: store)
            XCTAssertEqual(out.width, 64)
            XCTAssertNotNil(ImageHash.bytes(of: out))
        }
        _ = ResizeTool.apply(.init(width: 128, height: 64, interpolation: .lanczos, preventUpscale: false), to: input, contexts: store)
        scope.finish(); scope.finish()
        XCTAssertEqual(constructions.withLock { $0 }, 0)
        XCTAssertEqual(clears.withLock { $0 }, 0)
        XCTAssertEqual(relief.withLock { $0 }, 1, "idle non-Lanczos work still requests one allocator relief")
        XCTAssertEqual(store.stateForTesting().batchScopes, 0)
    }

    func testHeldParallelRendersAndOverlappingBatchesClearOnlyAfterLastUser() async throws {
        let clears = OSAllocatedUnfairLock(initialState: 0), relief = OSAllocatedUnfairLock(initialState: 0)
        let entered = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
        let store = ResizeContextStore(clearContext: { context in
            context.clearCaches(); clears.withLock { $0 += 1 }
        }, relieveAllocator: { relief.withLock { $0 += 1 } })
        let firstScope = store.beginBatch(), secondScope = store.beginBatch(), input = image()
        let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
        defer { firstGate.signal(); secondGate.signal(); firstScope.finish(); secondScope.finish() }
        let render: @Sendable (DispatchSemaphore) -> CGImage? = { gate in
            store.render { context in
                let output = context.createCGImage(CIImage(cgImage: input), from: CGRect(x: 0, y: 0, width: 128, height: 64),
                                                   format: .RGBA8, colorSpace: input.colorSpace ?? CGColorSpaceCreateDeviceRGB())
                entered.withLock { $0.append(ObjectIdentifier(context)) }
                _ = gate.wait(timeout: .now() + 5)
                return output
            }
        }
        let first = Task.detached { render(firstGate) }, second = Task.detached { render(secondGate) }
        guard await until({ entered.withLock { $0.count == 2 } }) else {
            firstGate.signal(); secondGate.signal()
            _ = await first.value; _ = await second.value
            return
        }
        XCTAssertEqual(store.stateForTesting().renderUsers, 2, "the context must support actual simultaneous renders")
        XCTAssertEqual(Set(entered.withLock { $0 }).count, 1, "one initialized generation is shared")
        firstScope.finish(); secondScope.finish()
        XCTAssertEqual(clears.withLock { $0 }, 0)
        firstGate.signal()
        let firstResult = await first.value
        XCTAssertEqual(store.stateForTesting().renderUsers, 1)
        XCTAssertEqual(clears.withLock { $0 }, 0)
        secondGate.signal()
        let secondResult = await second.value
        let firstImage = try XCTUnwrap(firstResult)
        let secondImage = try XCTUnwrap(secondResult)
        firstScope.finish(); secondScope.finish()
        XCTAssertEqual(clears.withLock { $0 }, 1)
        XCTAssertEqual(relief.withLock { $0 }, 1)
        XCTAssertFalse(store.stateForTesting().hasContext)
        // Read pixels only after the processing context has cleared.
        XCTAssertEqual(ImageHash.bytes(of: firstImage), ImageHash.bytes(of: input))
        XCTAssertEqual(ImageHash.bytes(of: secondImage), ImageHash.bytes(of: input))
    }

    func testRetiredContextCleanupDoesNotBlockOrClearNewGeneration() async throws {
        let clearing = OSAllocatedUnfairLock(initialState: 0), release = DispatchSemaphore(value: 0)
        let factory = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
        let store = ResizeContextStore(makeContext: {
            let context = CIContext(options: [.cacheIntermediates: false])
            factory.withLock { $0.append(ObjectIdentifier(context)) }
            return context
        }, clearContext: { context in
            let ordinal = clearing.withLock { $0 += 1; return $0 }
            if ordinal == 1 { _ = release.wait(timeout: .now() + 5) }
            context.clearCaches()
        }, relieveAllocator: {})
        let scope = store.beginBatch(), input = image()
        let old = ResizeTool.apply(.init(width: 64, height: 32, interpolation: .lanczos, preventUpscale: false), to: input, contexts: store)
        let oldPixels = try XCTUnwrap(ImageHash.bytes(of: old))
        let cleanup = Task.detached { scope.finish() }
        defer { release.signal() }
        guard await until({ clearing.withLock { $0 == 1 } }) else { release.signal(); await cleanup.value; return }
        let nextScope = store.beginBatch()
        let next = ResizeTool.apply(.init(width: 64, height: 32, interpolation: .lanczos, preventUpscale: false), to: input, contexts: store)
        XCTAssertEqual(factory.withLock { $0.count }, 2)
        XCTAssertEqual(Set(factory.withLock { $0 }).count, 2)
        XCTAssertEqual(ImageHash.bytes(of: next), oldPixels)
        release.signal(); await cleanup.value
        XCTAssertTrue(store.stateForTesting().hasContext, "retired cleanup must not detach the replacement")
        nextScope.finish()
        XCTAssertEqual(clearing.withLock { $0 }, 2)
        XCTAssertFalse(store.stateForTesting().hasContext)
        XCTAssertEqual(ImageHash.bytes(of: next), oldPixels)
    }

    func testCompletedResizeBatchClearsContextAndEncodedOutputRemainsValid() async throws {
        let tmp = EditTempDir("ResizeBatchLifetime"); defer { tmp.cleanup() }
        let src = try source(tmp), output = tmp.url.appendingPathComponent("output")
        let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let sourceDecoder = try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil))
        let sourceImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceDecoder, 0, nil))
        let expected = ResizeTool.apply(.init(width: 64, height: 32, interpolation: .lanczos, preventUpscale: false), to: sourceImage)
        let plan = BatchPlan(items: [ImageGroup(primary: src)], convert: .init(format: .png),
                             resize: .init(mode: .longEdge, value: 64), output: .folder(output))
        let result = try await Self.drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 1)
        XCTAssertEqual(ResizeTool.contexts.stateForTesting().batchScopes, 0)
        XCTAssertFalse(ResizeTool.contexts.stateForTesting().hasContext)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output.appendingPathComponent("source.png") as CFURL, nil))
        let actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(actual.width, 64); XCTAssertEqual(actual.height, 32)
        XCTAssertEqual(ImageHash.bytes(of: actual), ImageHash.bytes(of: expected))
    }

    func testValidationAndItemFailureUnwindBatchContextScope() async throws {
        let tmp = EditTempDir("ResizeFailedBatchLifetime"); defer { tmp.cleanup() }
        let src = try source(tmp), before = try Data(contentsOf: src)
        let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let ops = FileOps(metadata: nil, backups: backups, watchers: nil)
        warmSharedContext()
        let invalid = BatchPlan(items: [ImageGroup(primary: src)], output: .inPlace)
        do { _ = try await Self.drain(BatchRunner(fileOps: ops, backups: backups).run(invalid)); XCTFail("no operation") }
        catch BatchValidationError.noOperation {}
        XCTAssertEqual(ResizeTool.contexts.stateForTesting().batchScopes, 0)
        XCTAssertFalse(ResizeTool.contexts.stateForTesting().hasContext)
        warmSharedContext()
        let failing = BatchRunner(fileOps: ops, backups: backups, phaseCheckpoint: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let plan = BatchPlan(items: [ImageGroup(primary: src)], resize: .init(mode: .longEdge, value: 64),
                             output: .folder(tmp.url.appendingPathComponent("output")))
        let result = try await Self.drain(failing.run(plan))
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(ResizeTool.contexts.stateForTesting().batchScopes, 0)
        XCTAssertFalse(ResizeTool.contexts.stateForTesting().hasContext)
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func testStoppedBatchKeepsScopeUntilWorkerSettlesThenCleansUp() async throws {
        let tmp = EditTempDir("ResizeStoppedBatchLifetime"); defer { tmp.cleanup() }
        let src = try source(tmp), before = try Data(contentsOf: src), gate = ResizeBatchGate()
        let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
                                 phaseCheckpoint: { _, _ in await gate.wait() })
        warmSharedContext()
        let stop = BatchStop(), plan = BatchPlan(items: [ImageGroup(primary: src)], resize: .init(mode: .longEdge, value: 64),
                                                output: .folder(tmp.url.appendingPathComponent("output")))
        let updates = runner.run(plan, stop: stop)
        let work = Task<BatchResult, any Error> { [updates] in
            var final: BatchResult?
            for try await update in updates { if let result = update.result { final = result } }
            return try XCTUnwrap(final)
        }
        guard await until({ await gate.entered }) else { await gate.release(); _ = try? await work.value; return }
        stop.stop()
        XCTAssertEqual(ResizeTool.contexts.stateForTesting().batchScopes, 1)
        XCTAssertTrue(ResizeTool.contexts.stateForTesting().hasContext)
        XCTAssertFalse(stop.isSettled)
        await gate.release()
        let result = try await work.value
        XCTAssertEqual(result.cancelledCount, 1)
        XCTAssertEqual(ResizeTool.contexts.stateForTesting().batchScopes, 0)
        XCTAssertFalse(ResizeTool.contexts.stateForTesting().hasContext)
        XCTAssertEqual(try Data(contentsOf: src), before)
    }
}

private actor ResizeBatchGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

import Foundation

/// The cache's existing priority/slot queue bounds this executor. Both
/// macOS 14 and newer run blocking HEIC reads and ImageIO file decode
/// here rather than occupying the Swift cooperative thread pool.
enum ThumbnailBlockingIO {
    private static let queue = DispatchQueue(label: "app.shrike.thumbs.blocking-io", qos: .userInitiated, attributes: .concurrent)
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

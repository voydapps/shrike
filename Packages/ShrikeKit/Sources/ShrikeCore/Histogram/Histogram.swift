//
//  Histogram.swift
//  ShrikeCore
//
//  256-bin R / G / B / luminance histogram of a decoded image, computed on
//  the CPU with CoreGraphics + vImage.
//
//  Pipeline:
//    1. Point-sample the image into an sRGB 8-bit RGBA buffer no larger
//       than `maxSampleEdge` on the long side. CoreGraphics does the
//       colour conversion, so any source works: 8/16-bit, half/float,
//       Display P3, grey, CMYK, extended-range (clipped to 0...1).
//       Nearest-neighbour sampling (interpolation `.none`) is deliberate:
//       averaging would narrow the distribution and hide clipped pixels,
//       and it only touches the pixels it samples.
//    2. Un-premultiply if the image has alpha; fully transparent pixels
//       are excluded from every histogram.
//    3. `vImageHistogramCalculation_ARGB8888` for R, G, B (one pass).
//    4. Luminance with Rec.709 weights on the sRGB-encoded values
//       (`vImageMatrixMultiply_ARGB8888ToPlanar8`), then a planar
//       histogram. This matches what most viewers show as "luminosity".
//
//  A 512-px sample takes well under a millisecond on Apple silicon; see
//  HistogramTests.testPerformance for measured numbers.
//

import Foundation
import CoreGraphics
import Accelerate
import os

// MARK: - Result

public struct HistogramData: Sendable, Equatable {

    public static let binCount = 256

    /// Per-channel counts, 256 bins each, index = 8-bit sRGB value.
    public let red: [UInt32]
    public let green: [UInt32]
    public let blue: [UInt32]
    /// Rec.709 luminance (0.2126 R + 0.7152 G + 0.0722 B) of the
    /// sRGB-encoded values.
    public let luminance: [UInt32]
    /// Number of pixels counted (fully transparent pixels excluded).
    public let pixelCount: Int
    /// Size of the sample the histogram was computed from.
    public let sampleWidth: Int
    public let sampleHeight: Int
    /// Pixels with at least one of R, G, B at 0 / at 255 (the clip
    /// marks: "> 0.1 % of pixels at 0 or 255 in any channel").
    public let anyChannelShadowPixels: Int
    public let anyChannelHighlightPixels: Int

    public init(
        red: [UInt32], green: [UInt32], blue: [UInt32], luminance: [UInt32],
        pixelCount: Int, sampleWidth: Int, sampleHeight: Int,
        anyChannelShadowPixels: Int = 0, anyChannelHighlightPixels: Int = 0
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.pixelCount = pixelCount
        self.sampleWidth = sampleWidth
        self.sampleHeight = sampleHeight
        self.anyChannelShadowPixels = anyChannelShadowPixels
        self.anyChannelHighlightPixels = anyChannelHighlightPixels
    }

    /// No pixels.
    public static let empty = HistogramData(
        red: Array(repeating: 0, count: binCount), green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount), luminance: Array(repeating: 0, count: binCount),
        pixelCount: 0, sampleWidth: 0, sampleHeight: 0
    )

    /// Percentage (0–100) of pixels whose luminance is pure black (bin 0).
    public var shadowsClippedPercent: Double {
        percent(luminance[0])
    }

    /// Percentage (0–100) of pixels whose luminance is pure white (bin 255).
    public var highlightsClippedPercent: Double {
        percent(luminance[255])
    }

    /// Percentage of pixels with any channel at 0 (shadow clip mark).
    public var anyChannelShadowsClippedPercent: Double {
        percent(anyChannelShadowPixels)
    }

    /// Percentage of pixels with any channel at 255 (highlight clip mark).
    public var anyChannelHighlightsClippedPercent: Double {
        percent(anyChannelHighlightPixels)
    }

    /// Mean luminance as 0-100 % ("Average brightness 46 percent").
    public var meanLuminancePercent: Double {
        guard pixelCount > 0 else { return 0 }
        var sum = 0.0
        for (value, count) in luminance.enumerated() { sum += Double(value) * Double(count) }
        return sum / Double(pixelCount) / 255 * 100
    }

    public enum Channel: Sendable, CaseIterable {
        case red, green, blue, luminance
    }

    public func bins(_ channel: Channel) -> [UInt32] {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        case .luminance: return luminance
        }
    }

    /// Percentage of pixels at 0 / 255 in one channel — for per-channel
    /// clipping warnings.
    public func clippedPercent(_ channel: Channel) -> (shadows: Double, highlights: Double) {
        let b = bins(channel)
        return (percent(b[0]), percent(b[255]))
    }

    /// Largest bin across all four channels, for normalising a drawing.
    /// `excludingEnds` skips bins 0 and 255 so a clipped spike doesn't
    /// flatten the rest of the curve.
    public func maxBinCount(excludingEnds: Bool = false) -> UInt32 {
        let range = excludingEnds ? 1..<255 : 0..<256
        var best: UInt32 = 0
        for channel in [red, green, blue, luminance] {
            for i in range where channel[i] > best { best = channel[i] }
        }
        return best
    }

    private func percent(_ count: UInt32) -> Double {
        percent(Int(count))
    }

    private func percent(_ count: Int) -> Double {
        pixelCount == 0 ? 0 : Double(count) * 100 / Double(pixelCount)
    }
}

// MARK: - Computation

public enum Histogram {

    /// Computes the histogram off the caller's actor. `maxSampleEdge`
    /// caps the long side of the sample (never histogram 50 MP at full
    /// size; 512 px is statistically plenty).
    public static func compute(from image: CGImage, maxSampleEdge: Int = 512) async -> HistogramData {
        computeSync(from: image, maxSampleEdge: maxSampleEdge)
    }

    /// Synchronous variant for callers already on a background queue.
    public static func computeSync(from image: CGImage, maxSampleEdge: Int = 512) -> HistogramData {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0, maxSampleEdge > 0 else { return .empty }

        let scale = min(1.0, Double(maxSampleEdge) / Double(max(srcW, srcH)))
        let width = max(1, Int((Double(srcW) * scale).rounded()))
        let height = max(1, Int((Double(srcH) * scale).rounded()))
        let rowBytes = width * 4
        let hasAlpha = Self.hasAlpha(image)

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return .empty }
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes * height)

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | (hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                        : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(
            data: pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: srgb, bitmapInfo: bitmapInfo
        ) else { return .empty }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buffer = vImage_Buffer(
            data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        if hasAlpha {
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
        // (Opaque images: the 4th byte is undefined with noneSkipLast; the
        // luminance matrix ignores it and so does the correction below.)

        // R, G, B, A in one pass (vImage's "ARGB" is just memory order).
        var r = [vImagePixelCount](repeating: 0, count: 256)
        var g = [vImagePixelCount](repeating: 0, count: 256)
        var b = [vImagePixelCount](repeating: 0, count: 256)
        var a = [vImagePixelCount](repeating: 0, count: 256)
        r.withUnsafeMutableBufferPointer { rp in
            g.withUnsafeMutableBufferPointer { gp in
                b.withUnsafeMutableBufferPointer { bp in
                    a.withUnsafeMutableBufferPointer { ap in
                        var channels: [UnsafeMutablePointer<vImagePixelCount>?] = [
                            rp.baseAddress, gp.baseAddress, bp.baseAddress, ap.baseAddress,
                        ]
                        _ = channels.withUnsafeMutableBufferPointer { cp in
                            vImageHistogramCalculation_ARGB8888(
                                &buffer, cp.baseAddress!, vImage_Flags(kvImageNoFlags)
                            )
                        }
                    }
                }
            }
        }

        // Luminance plane (Rec.709, fixed point /32768, rounded).
        let lumaPixels = UnsafeMutableRawPointer.allocate(byteCount: width * height, alignment: 64)
        defer { lumaPixels.deallocate() }
        var luma = vImage_Buffer(
            data: lumaPixels, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: width
        )
        let matrix: [Int16] = [6966, 23436, 2366, 0]   // R, G, B, A; sums to 32768
        vImageMatrixMultiply_ARGB8888ToPlanar8(
            &buffer, &luma, matrix, 32768, nil, 16384, vImage_Flags(kvImageNoFlags)
        )
        var l = [vImagePixelCount](repeating: 0, count: 256)
        vImageHistogramCalculation_Planar8(&luma, &l, vImage_Flags(kvImageNoFlags))

        // "Any channel clipped" is a union across channels. Done in vImage
        // so it stays fast in debug builds too.
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        defer { scratch.deallocate() }
        var scratchBuffer = vImage_Buffer(
            data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        let anyShadow = countPixelsWithAnyChannel(
            at: 0, source: &buffer, scratch: &scratchBuffer, plane: &luma, hasAlpha: hasAlpha)
        let anyHighlight = countPixelsWithAnyChannel(
            at: 255, source: &buffer, scratch: &scratchBuffer, plane: &luma, hasAlpha: hasAlpha)

        // Fully transparent pixels are RGB 0 / luma 0 after unpremultiply;
        // take them back out of bin 0.
        let transparent = hasAlpha ? a[0] : 0
        if transparent > 0 {
            r[0] -= min(r[0], transparent)
            g[0] -= min(g[0], transparent)
            b[0] -= min(b[0], transparent)
            l[0] -= min(l[0], transparent)
        }

        return HistogramData(
            red: r.map { UInt32(clamping: $0) },
            green: g.map { UInt32(clamping: $0) },
            blue: b.map { UInt32(clamping: $0) },
            luminance: l.map { UInt32(clamping: $0) },
            pixelCount: width * height - Int(transparent),
            sampleWidth: width,
            sampleHeight: height,
            anyChannelShadowPixels: anyShadow,
            anyChannelHighlightPixels: anyHighlight
        )
    }

    /// Counts pixels where R, G or B equals `value`, skipping fully
    /// transparent pixels. A lookup table turns each colour byte into 1
    /// (match) or 0 and the alpha byte into 4 (transparent) or 0; a
    /// [1, 1, 1, 1] matrix sums them per pixel; bins 1–3 of the result are
    /// the opaque pixels with at least one match.
    private static func countPixelsWithAnyChannel(
        at value: UInt8,
        source: inout vImage_Buffer,
        scratch: inout vImage_Buffer,
        plane: inout vImage_Buffer,
        hasAlpha: Bool
    ) -> Int {
        var channelTable = [Pixel_8](repeating: 0, count: 256)
        channelTable[Int(value)] = 1
        var alphaTable = [Pixel_8](repeating: 0, count: 256)
        if hasAlpha { alphaTable[0] = 4 }
        // Memory order is R, G, B, A; vImage names the tables for ARGB
        // but applies them by byte position.
        vImageTableLookUp_ARGB8888(
            &source, &scratch, channelTable, channelTable, channelTable, alphaTable,
            vImage_Flags(kvImageNoFlags)
        )
        let sum: [Int16] = [1, 1, 1, 1]
        vImageMatrixMultiply_ARGB8888ToPlanar8(
            &scratch, &plane, sum, 1, nil, 0, vImage_Flags(kvImageNoFlags)
        )
        var counts = [vImagePixelCount](repeating: 0, count: 256)
        vImageHistogramCalculation_Planar8(&plane, &counts, vImage_Flags(kvImageNoFlags))
        return Int(counts[1] + counts[2] + counts[3])
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

// MARK: - Latest-request-wins front end

/// The viewer's histogram source:
/// computes off the main thread on a sample of at most 1024 px, and only
/// the newest request gets a result. An older request that finishes after
/// a newer one was made returns nil, so a slow histogram for the previous
/// image can never overwrite the current one.
///
/// "Newest" is decided by `begin()`, called where the request is made and
/// in request order (the viewer calls it on the main actor). It is not
/// decided by when the async work reaches the calculator: two requests can
/// arrive in either order (a slow file sample for the older image can
/// arrive last), and the older one would then win while the current image
/// got nil.
public final class HistogramCalculator: Sendable {

    /// One request's place in line. Take it with `begin()`.
    public struct Request: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    public static let defaultMaxSampleEdge = 1024

    private let latest = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    public init() {}

    /// Starts a request; it supersedes every earlier one. Synchronous, so
    /// the caller's order is the order that counts.
    public func begin() -> Request {
        latest.withLock { generation in
            generation &+= 1
            return Request(generation: generation)
        }
    }

    /// True while no newer request began and `cancelAll()` wasn't called.
    public func isLatest(_ request: Request) -> Bool {
        latest.withLock { $0 == request.generation }
    }

    /// Returns nil when a newer request began before or during the work.
    /// Work for a request that is already superseded is skipped.
    public func compute(
        from image: CGImage, maxSampleEdge: Int = HistogramCalculator.defaultMaxSampleEdge,
        for request: Request
    ) async -> HistogramData? {
        guard isLatest(request) else { return nil }
        let result = await Histogram.compute(from: image, maxSampleEdge: maxSampleEdge)
        return isLatest(request) ? result : nil
    }

    /// Begins a request now and computes it.
    public func compute(
        from image: CGImage, maxSampleEdge: Int = HistogramCalculator.defaultMaxSampleEdge
    ) async -> HistogramData? {
        await compute(from: image, maxSampleEdge: maxSampleEdge, for: begin())
    }

    /// Invalidates any request in flight (e.g. the viewer closed).
    public func cancelAll() {
        latest.withLock { $0 &+= 1 }
    }
}

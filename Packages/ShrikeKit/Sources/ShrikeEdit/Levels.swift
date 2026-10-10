//
//  Levels.swift
//  ShrikeEdit
//
//  Levels. Five handles per channel: input
//  black / white, gamma (midtones), output black / white. The master (RGB)
//  channel applies first, then Red, Green, Blue. Replayed as one
//  256-entry lookup table per channel on 8-bit gamma-encoded values
//  (vImage), so a handle value maps to an exact output value: "input
//  black 20 → every pixel ≤ 20 becomes 0".
//
//  The live Metal preview must use the same tables (`lutTextureBytes`),
//  applied to the encoded (non-linear) values, so preview and export
//  match.
//

import Accelerate
import ShrikeCore
import CoreGraphics
import Foundation

// MARK: - Parameters

/// One channel's five handles.
public struct LevelsChannel: Sendable, Codable, Equatable, Hashable {
    public var inBlack: UInt8
    public var inWhite: UInt8
    /// Midtones. 1.00 = identity; > 1 brightens (Photoshop convention).
    public var gamma: Double
    public var outBlack: UInt8
    public var outWhite: UInt8

    public static let gammaRange: ClosedRange<Double> = 0.10...9.99

    public init(inBlack: UInt8 = 0, inWhite: UInt8 = 255, gamma: Double = 1,
                outBlack: UInt8 = 0, outWhite: UInt8 = 255) {
        self.inBlack = inBlack
        self.inWhite = inWhite
        self.gamma = gamma
        self.outBlack = outBlack
        self.outWhite = outWhite
    }

    public static let identity = LevelsChannel()

    public var isIdentity: Bool { normalized() == .identity }

    /// Clamped to the valid ranges: black ≤ white − 2, gamma 0.10…9.99.
    public func normalized() -> LevelsChannel {
        var c = self
        if !c.gamma.isFinite { c.gamma = 1 }
        c.gamma = min(max(c.gamma, Self.gammaRange.lowerBound), Self.gammaRange.upperBound)
        c.inBlack = min(c.inBlack, 253)
        if Int(c.inWhite) < Int(c.inBlack) + 2 { c.inWhite = c.inBlack + 2 }
        return c
    }

    /// 256-entry table for this channel alone.
    public func lut() -> [UInt8] {
        let c = normalized()
        let lo = Double(c.inBlack), hi = Double(c.inWhite)
        let oLo = Double(c.outBlack), oHi = Double(c.outWhite)
        let invGamma = 1 / c.gamma
        return (0..<256).map { v in
            let x = min(max((Double(v) - lo) / (hi - lo), 0), 1)
            let y = pow(x, invGamma)
            return UInt8(clamping: Int((oLo + y * (oHi - oLo)).rounded()))
        }
    }
}

public struct LevelsParams: Sendable, Codable, Equatable, Hashable {
    /// The "RGB" channel — applies first.
    public var master: LevelsChannel
    public var red: LevelsChannel
    public var green: LevelsChannel
    public var blue: LevelsChannel

    public init(master: LevelsChannel = .identity, red: LevelsChannel = .identity,
                green: LevelsChannel = .identity, blue: LevelsChannel = .identity) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = LevelsParams()

    public var isIdentity: Bool {
        master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    /// Final per-channel tables: `channel.lut[master.lut[v]]`.
    public func composedLUTs() -> (red: [UInt8], green: [UInt8], blue: [UInt8]) {
        let m = master.lut()
        func compose(_ c: LevelsChannel) -> [UInt8] {
            let t = c.lut()
            return m.map { t[Int($0)] }
        }
        return (compose(red), compose(green), compose(blue))
    }

    /// 256 × 1 RGBA8 texels (R, G, B tables; A = 255) for the Metal
    /// preview: sample at `(v * 255 + 0.5) / 256` per channel, on encoded
    /// values, nearest filtering.
    public func lutTextureBytes() -> [UInt8] {
        let t = composedLUTs()
        var out = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            out[i * 4] = t.red[i]
            out[i * 4 + 1] = t.green[i]
            out[i * 4 + 2] = t.blue[i]
        }
        return out
    }

    /// "Auto Color": per-channel black and white points at `clip` (0.1 %)
    /// clipping each side, gamma 1.00, master left at identity. Each
    /// channel is stretched on its own, so a colour cast goes away. A
    /// channel with too narrow a spread stays at identity. `histogram` is
    /// the `HistogramCalculator` result for the image being edited.
    public static func autoColor(from histogram: HistogramData, clip: Double = 0.001) -> LevelsParams {
        LevelsParams(red: stretch(histogram.red, clip: clip),
                     green: stretch(histogram.green, clip: clip),
                     blue: stretch(histogram.blue, clip: clip))
    }

    /// "Auto Contrast" (the default Auto): stretches brightness and
    /// contrast without changing the colour balance. One combined histogram
    /// (red + green + blue bins, not luminance: a bright saturated red has
    /// a low luminance and would clip) gives black and white at `clip` of
    /// all channel samples, each side. They go in the master (RGB)
    /// channel with gamma 1.00; R, G and B stay identity. A spread under 2
    /// → identity.
    public static func autoContrast(from histogram: HistogramData, clip: Double = 0.001) -> LevelsParams {
        guard histogram.red.count == 256, histogram.green.count == 256, histogram.blue.count == 256
        else { return .identity }
        var combined = [UInt64](repeating: 0, count: 256)
        for v in 0..<256 {
            combined[v] = UInt64(histogram.red[v]) + UInt64(histogram.green[v]) + UInt64(histogram.blue[v])
        }
        return LevelsParams(master: stretch(combined, clip: clip))
    }

    /// Black / white points of one histogram. `darkest` is the first bin
    /// where the running count from the dark end passes `clip` of the
    /// total; the black point sits one below it, so only the samples under
    /// that bin (at most `clip`) end at 0. Same for white. Fewer than 2
    /// levels between `darkest` and `brightest` → identity.
    private static func stretch<T: BinaryInteger>(_ bins: [T], clip: Double) -> LevelsChannel {
        guard bins.count == 256 else { return .identity }
        let total = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return .identity }
        let limit = Double(total) * max(0, clip)
        var acc: UInt64 = 0
        var black = 0
        for v in 0..<256 {
            acc += UInt64(bins[v])
            if Double(acc) > limit { black = v; break }
        }
        acc = 0
        var white = 255
        for v in stride(from: 255, through: 0, by: -1) {
            acc += UInt64(bins[v])
            if Double(acc) > limit { white = v; break }
        }
        guard white - black >= 2 else { return .identity }
        return LevelsChannel(inBlack: UInt8(max(black - 1, 0)), inWhite: UInt8(min(white + 1, 255)))
    }
}

// MARK: - Render

public enum LevelsTool {

    /// Apply `params` to `image` as exact 8-bit per-channel lookups in the
    /// image's own RGB colour space (sRGB for non-RGB sources). Alpha is
    /// untouched (non-premultiplied while the tables run). Returns the
    /// input unchanged for identity or on any vImage failure.
    public static func apply(_ params: LevelsParams, to image: CGImage) -> CGImage {
        if params.isIdentity { return image }
        let space: CGColorSpace = {
            if let cs = image.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let alpha: CGImageAlphaInfo = hasAlpha ? .last : .noneSkipLast
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue)),
              var buffer = try? vImage_Buffer(cgImage: image, format: format)
        else { return image }
        defer { buffer.free() }

        let t = params.composedLUTs()
        // Tables apply by byte position; the layout is R, G, B, A.
        let err = t.red.withUnsafeBufferPointer { r in
            t.green.withUnsafeBufferPointer { g in
                t.blue.withUnsafeBufferPointer { b in
                    vImageTableLookUp_ARGB8888(&buffer, &buffer, r.baseAddress, g.baseAddress,
                                               b.baseAddress, nil, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard err == kvImageNoError, let out = try? buffer.createCGImage(format: format) else {
            return image
        }
        return out
    }
}

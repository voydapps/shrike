//
//  ShrikeEditTests.swift
//  ShrikeEditTests
//
//  Shared helpers. The tests live in EditRecipeTests,
//  ExporterTests, LosslessRotatorTests, RecipeToolParamsTests,
//  PrefsEditKeysTests.
//
//  Coverage map:
//    Recipe round-trip identity          → EditRecipeTests
//    Order-sensitivity                   → EditRecipeTests
//    Coalescing preserves one step       → EditRecipeTests
//    Undo / redo symmetry                → EditRecipeTests
//    Atomic rename survives IO failure   → ExporterTests
//    JPEG rotate preserves EXIF (orient) → LosslessRotatorTests
//    Trash original survives rotate      → LosslessRotatorTests
//    Non-JPEG ⌘R falls through           → ExporterTests (recipe-path proof)
//    Edit mode suppresses navigation     → UI tests (not covered here)
//    Exit-modal appears on unsaved edit  → UI tests (not covered here)
//    Latest-wins drops intermediates     → RecipeToolParamsTests
//    Prefs round-trip                    → PrefsEditKeysTests
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Shared fixture helper — equivalent to `ShrikeCoreTests.TestFixture`
/// but scoped to this test target's bundle.
enum EditFixture {
    static func url(_ name: String) throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        if let dir = bundle.resourceURL?.appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        {
            return dir.appendingPathComponent(name)
        }
        throw NSError(
            domain: "ShrikeEditTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fixture \(name) not found in test bundle"]
        )
    }

    /// Load the fixture as a `CGImage`.
    static func cgImage(_ name: String) throws -> CGImage {
        let url = try url(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw NSError(
                domain: "ShrikeEditTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "failed to decode \(name)"]
            )
        }
        return img
    }

    /// Build a synthetic solid-colour `CGImage`. Useful for ops tests
    /// that don't need a real JPEG.
    static func solidRGB(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

/// Scoped temp directory.
final class EditTempDir {
    let url: URL
    init(_ label: String = "ShrikeEditTests") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = root
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Hash a `CGImage`'s pixel bytes for identity comparisons.
/// Strategy: draw into a known RGBA8 context at the image's own size,
/// SHA-256 the data-provider's bytes. Proves byte equality modulo the
/// conversion path.
enum ImageHash {
    static func bytes(of image: CGImage) -> Data? {
        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: w * h * 4)
    }
}

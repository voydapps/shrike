#!/usr/bin/env swift
// Generate test fixtures for ShrikeCoreTests.
// Run from an empty folder: `swift /path/to/generate-test-fixtures.swift`,
// then copy the files you need into Tests/*/Fixtures. (The JPEG with an
// embedded preview comes from generate-embedded-preview-fixture.py.)
// Output files: small.jpg, small.png, small.heic, corrupt.jpg,
// landscape_with_exif.jpg.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makeImage(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitsPerComponent = 8
    let bytesPerRow = width * 4
    let ctx = CGContext(
        data: nil,
        width: width, height: height,
        bitsPerComponent: bitsPerComponent,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(
        red: CGFloat(rgb.0) / 255.0,
        green: CGFloat(rgb.1) / 255.0,
        blue: CGFloat(rgb.2) / 255.0,
        alpha: 1
    )
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    for i in stride(from: 0, to: width, by: 16) {
        ctx.fill(CGRect(x: i, y: i, width: 4, height: 4))
    }
    return ctx.makeImage()!
}

func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: CGFloat = 0.85) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil
    ) else { fatalError("dest failed for \(url.path)") }
    let opts: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
    ]
    CGImageDestinationAddImage(dest, image, opts as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        fatalError("finalize failed for \(url.path)")
    }
}

func writeImageWithExif(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else { fatalError("dest failed") }
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2024:06:15 10:30:00",
        kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifExposureTime: 1.0 / 250.0,
        kCGImagePropertyExifISOSpeedRatings: [100],
        kCGImagePropertyExifFocalLength: 50.0,
        kCGImagePropertyExifLensModel: "Test 50mm f/1.8",
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "Shrike Test",
        kCGImagePropertyTIFFModel: "Fixture",
    ]
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImageDestinationLossyCompressionQuality: 0.85,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        fatalError("finalize failed")
    }
}

let fm = FileManager.default
let here = URL(fileURLWithPath: fm.currentDirectoryPath)

let smallRed = makeImage(width: 128, height: 128, rgb: (220, 20, 20))
writeImage(smallRed, to: here.appendingPathComponent("small.jpg"), type: .jpeg, quality: 0.7)

let smallBlue = makeImage(width: 64, height: 64, rgb: (20, 20, 220))
writeImage(smallBlue, to: here.appendingPathComponent("small.png"), type: .png)

let smallGreen = makeImage(width: 96, height: 96, rgb: (20, 220, 20))
writeImage(smallGreen, to: here.appendingPathComponent("small.heic"), type: .heic, quality: 0.7)

var rng = SystemRandomNumberGenerator()
var buf = Data(count: 512)
for i in 0..<buf.count {
    buf[i] = UInt8.random(in: 0...255, using: &rng)
}
try buf.write(to: here.appendingPathComponent("corrupt.jpg"))

let landscape = makeImage(width: 192, height: 128, rgb: (230, 130, 30))
writeImageWithExif(landscape, to: here.appendingPathComponent("landscape_with_exif.jpg"))

print("Generated fixtures in \(here.path)")
for fn in ["small.jpg", "small.png", "small.heic", "corrupt.jpg", "landscape_with_exif.jpg"] {
    let u = here.appendingPathComponent(fn)
    let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1
    print("  \(fn): \(size) bytes")
}

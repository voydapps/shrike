//
//  ShrikeAccentTests.swift
//  ShrikeUITests
//
//  Spec 27 P3-1: two accent tokens for what Shrike draws itself.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class ShrikeAccentTests: XCTestCase {

    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI")
    }

    func testNoHandWrittenAccentOutsideShrikeAccent() throws {
        let files = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for url in files where url.lastPathComponent != "ShrikeAccent.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("controlAccentColor.blended"), "\(url.lastPathComponent): use ShrikeAccent.mark")
            XCTAssertNil(text.range(of: #"NSColor\(\s*(srgbRed|red|calibratedRed|deviceRed)[^)]*\)\s*//\s*accent"#,
                                    options: .regularExpression), url.lastPathComponent)
        }
    }

    /// Everything Shrike draws takes `ShrikeAccent.mark` / `.fill`; the only other
    /// reader of the system accent is `AccentFill` (it recognises the system default button).
    func testNoRawSystemAccentOutsideTheTokens() throws {
        let files = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for url in files where !["ShrikeAccent.swift", "AccentFill.swift"].contains(url.lastPathComponent) {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code {
                XCTAssertFalse(line.contains("controlAccentColor"), "\(url.lastPathComponent): \(line)")
            }
        }
    }

    func testMarkIsLighterThanFill() throws {
        let mark = try XCTUnwrap(ShrikeAccent.mark.usingColorSpace(.sRGB))
        let fill = try XCTUnwrap(ShrikeAccent.fill.usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(mark.redComponent, fill.redComponent)
        XCTAssertGreaterThanOrEqual(mark.greenComponent, fill.greenComponent)
        XCTAssertEqual(ShrikeAccent.fill, .controlAccentColor)
    }

    func testCallSitesUseMark() {
        let toast = ToastHostView(placement: .viewer)
        XCTAssertEqual(toast.actionButtonForTesting.contentTintColor, ShrikeAccent.mark)
        XCTAssertEqual(CompareFocusRingView.width, 3)
    }
}

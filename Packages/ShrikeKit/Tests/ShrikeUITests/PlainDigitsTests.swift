//
//  PlainDigitsTests.swift
//  ShrikeUITests
//
//  SwiftUI's `Text("\(n)")` is a localized key, so a
//  locale with a dot or a space for thousands showed a 3456 px side as
//  "3.456" (it_IT) or "3 456" (ru_RU). Pixel sizes, px / pt values and
//  counters are plain digits in every locale.
//
//  SwiftUI builds no accessibility tree and no pop-up buttons in a window
//  that is never shown, so the inspector's File rows are rendered to an
//  image under it_IT and under ru_RU: with plain digits the two images
//  are the same. The control test proves the renderer does see the
//  locale. A source scan keeps any new `Text("…\(n)…")` out of the UI
//  (it covers the Preferences pop-ups).
//

import XCTest
import SwiftUI
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class PlainDigitsTests: XCTestCase {

    private static let italian = Locale(identifier: "it_IT")
    private static let russian = Locale(identifier: "ru_RU")

    private func pixels(_ view: some View, locale: Locale) throws -> Data {
        let renderer = ImageRenderer(content: view.environment(\.locale, locale).frame(width: 280))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "rendered")
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    /// Control: a localized `Text("\(3456) px")` renders differently under
    /// it_IT ("3.456") and ru_RU ("3 456"), so equal images below mean
    /// plain digits, not a renderer that ignores the locale.
    func testTheRendererSeesTheLocale() throws {
        let n = 3456
        let localized = Text("\(n) px")
        XCTAssertNotEqual(try pixels(localized, locale: Self.italian), try pixels(localized, locale: Self.russian))
        let plain = Text(verbatim: "\(n) px")
        XCTAssertEqual(try pixels(plain, locale: Self.italian), try pixels(plain, locale: Self.russian))
    }

    func testInspectorDimensionsArePlainDigits() throws {
        var state = InspectorState(count: 1, commonName: "IMG_0001.jpg", commonWidth: 3456, commonHeight: 5184)
        state.commonType = .jpeg
        let section = InspectorPaneController.fileInfoSectionForTesting(state)
        let italian = try pixels(section, locale: Self.italian)
        XCTAssertEqual(italian, try pixels(section, locale: Self.russian),
                       "Dimensions reads 3456 × 5184 in both locales")
        let reference = VStack { Text(verbatim: "3456 × 5184") }
        XCTAssertNotEqual(try pixels(reference, locale: Self.italian), italian, "sanity: the section is drawn")
    }

    /// No SwiftUI text in ShrikeUI interpolates into a localized key: pixel
    /// sizes, px / pt values and counters go through `Text(verbatim:)`.
    func testNoLocalizedNumberKeysInTheUI() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let sources = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"\bText\("[^"]*\\\("#)
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the sources were found")
        XCTAssertEqual(offenders, [], "use Text(verbatim:) for numbers")
    }
}

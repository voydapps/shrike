//
//  NoPlaceholderCopyTests.swift
//  ShrikeUITests
//
//  (regex): no string literal in the
//  shipping sources may promise a later version. Comments are ignored.
//

import XCTest

final class NoPlaceholderCopyTests: XCTestCase {

    func testNoPlaceholderStringLiterals() throws {
        // Tests/ShrikeUITests/<this file> → the repo root is four levels up.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = ["Packages/ShrikeKit/Sources", "App/Sources"].map { repo.appendingPathComponent($0) }
        let pattern = try NSRegularExpression(
            pattern: #"v1\.1|\(task \d|coming (soon|in)|not yet|not wired|will appear here"#,
            options: [.caseInsensitive])
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var scanned = 0
        var hits: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, rawLine) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") { continue }
                    let line = rawLine as NSString
                    for m in literal.matches(in: rawLine, range: NSRange(location: 0, length: line.length)) {
                        let lit = line.substring(with: m.range)
                        if pattern.firstMatch(in: lit, range: NSRange(location: 0, length: (lit as NSString).length)) != nil {
                            hits.append("\(url.lastPathComponent):\(n + 1) \(lit)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "found the sources")
        XCTAssertEqual(hits, [], "placeholder copy in shipping strings")
    }
}

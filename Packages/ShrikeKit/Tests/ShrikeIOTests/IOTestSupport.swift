//
//  IOTestSupport.swift
//  ShrikeIOTests
//
//  Temp-dir helper. Every IO test works inside its own directory under
//  NSTemporaryDirectory — never in the user's real folders.
//

import Foundation

final class IOTempDir {
    let url: URL

    init(_ label: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeIOTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Resolve /var → /private/var once so path comparisons are stable.
        self.url = root.resolvingSymlinksInPath()
    }

    @discardableResult
    func file(_ name: String, _ contents: String = "data", in sub: String? = nil) throws -> URL {
        var dir = url
        if let sub {
            dir = url.appendingPathComponent(sub, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let f = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: f)
        return f
    }

    func dir(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

func readString(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
}

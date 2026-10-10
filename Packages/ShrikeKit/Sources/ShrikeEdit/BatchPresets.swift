//
//  BatchPresets.swift
//  ShrikeEdit
//
//  Batch window presets. Stored in
//  `<ShrikeDataPaths.applicationSupport>/BatchPresets.plist`
//  (`~/Library/Application Support/app.shrike/` in the app, a
//  temp folder under XCTest). Built-in presets are not stored and can't be
//  renamed, replaced or deleted.
//

import Foundation
import ShrikeCore

/// One saved set of Batch window options.
public struct BatchPreset: Sendable, Hashable, Codable {
    public var name: String
    public var convert: ConvertOptions?
    public var resize: ResizeOptions?
    /// Quarter turns clockwise (as `BatchPlan.rotate`).
    public var rotate: Int?
    /// Rename template source text, e.g. "{yyyy-MM-dd}_{counter:000}".
    public var renameTemplate: String?
    public var renameStart: Int
    public var renameCase: NameCase?
    /// Output folder path; nil = the default "<source folder>/Shrike Export".
    public var outputFolderPath: String?

    public init(name: String, convert: ConvertOptions? = nil, resize: ResizeOptions? = nil,
                rotate: Int? = nil, renameTemplate: String? = nil, renameStart: Int = 1,
                renameCase: NameCase? = nil, outputFolderPath: String? = nil) {
        self.name = name
        self.convert = convert
        self.resize = resize
        self.rotate = rotate
        self.renameTemplate = renameTemplate
        self.renameStart = renameStart
        self.renameCase = renameCase
        self.outputFolderPath = outputFolderPath
    }
}

public enum BatchPresetError: Error, Equatable, Sendable {
    /// Empty name after trimming spaces.
    case emptyName
    /// The name belongs to a built-in preset.
    case builtInName(String)
    /// Another saved preset already uses this name (rename only).
    case nameTaken(String)
    case notFound(String)
    case writeFailed(String)
}

public actor BatchPresetStore {

    public static let fileName = "BatchPresets.plist"

    /// Built-ins, in menu order.
    public static let builtIns: [BatchPreset] = [
        BatchPreset(name: "Web 2048",
                    convert: ConvertOptions(format: .jpeg, quality: 0.85),
                    resize: ResizeOptions(mode: .longEdge, value: 2048)),
        BatchPreset(name: "Email 1280",
                    convert: ConvertOptions(format: .jpeg, quality: 0.80),
                    resize: ResizeOptions(mode: .longEdge, value: 1280)),
        BatchPreset(name: "Rename by date", renameTemplate: "{yyyy-MM-dd}_{counter:000}"),
    ]

    public static var defaultURL: URL {
        ShrikeDataPaths.applicationSupport.appendingPathComponent(fileName)
    }

    public nonisolated let fileURL: URL
    private var saved: [BatchPreset]?

    public init(fileURL: URL = BatchPresetStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static func isBuiltIn(_ name: String) -> Bool {
        builtIns.contains { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Built-ins first, then the user's presets in the order saved.
    public func list() -> [BatchPreset] {
        Self.builtIns + load()
    }

    /// The user's presets only.
    public func savedPresets() -> [BatchPreset] { load() }

    /// "Save Preset…": adds `preset`, or replaces the saved preset with the
    /// same name (case-insensitive).
    public func save(_ preset: BatchPreset) throws {
        var preset = preset
        preset.name = try Self.validName(preset.name)
        var all = load()
        if let i = all.firstIndex(where: { Self.same($0.name, preset.name) }) {
            all[i] = preset
        } else {
            all.append(preset)
        }
        try write(all)
    }

    public func rename(_ name: String, to newName: String) throws {
        let target = try Self.validName(newName)
        var all = load()
        guard let i = all.firstIndex(where: { Self.same($0.name, name) }) else {
            throw BatchPresetError.notFound(name)
        }
        if all.indices.contains(where: { $0 != i && Self.same(all[$0].name, target) }) {
            throw BatchPresetError.nameTaken(target)
        }
        all[i].name = target
        try write(all)
    }

    /// "Delete “Name”".
    public func delete(named name: String) throws {
        if Self.isBuiltIn(name) { throw BatchPresetError.builtInName(name) }
        var all = load()
        guard let i = all.firstIndex(where: { Self.same($0.name, name) }) else {
            throw BatchPresetError.notFound(name)
        }
        all.remove(at: i)
        try write(all)
    }

    // MARK: - Storage

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    private static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BatchPresetError.emptyName }
        if isBuiltIn(name) { throw BatchPresetError.builtInName(name) }
        return name
    }

    private struct FileBody: Codable {
        var version = 1
        var presets: [BatchPreset]
    }

    /// A missing or unreadable file reads as "no saved presets".
    private func load() -> [BatchPreset] {
        if let saved { return saved }
        let presets = (try? Data(contentsOf: fileURL))
            .flatMap { try? PropertyListDecoder().decode(FileBody.self, from: $0) }?.presets ?? []
        saved = presets
        return presets
    }

    private func write(_ presets: [BatchPreset]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(FileBody(presets: presets)).write(to: fileURL, options: .atomic)
            saved = presets
        } catch {
            throw BatchPresetError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Show in Maps

public enum MapsLink {
    /// `https://maps.apple.com/?ll=<lat>,<lon>&q=<file name>`, coordinates
    /// signed (south / west negative). Nil when out of range.
    public static func url(latitude: Double, longitude: Double, fileName: String) -> URL? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [
            URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)),
            URLQueryItem(name: "q", value: fileName),
        ]
        return parts.url
    }
}

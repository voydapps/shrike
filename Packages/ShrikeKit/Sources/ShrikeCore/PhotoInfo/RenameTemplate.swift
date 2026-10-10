//
//  RenameTemplate.swift
//  ShrikeCore
//
//  Batch-rename templates. A template is literal text with
//  `{token}` / `{token:argument}` placeholders:
//
//      {name} {name:lower} {name:upper}     original stem
//      {counter} {counter:000} {counter:4}  counter, zero-padded; start is
//                                           `counterStart`
//      {yyyy} {MM} {dd} {yyyy-MM-dd} {HH-mm-ss}
//      {date:FORMAT}                        date taken, else file date
//      {filedate:FORMAT}                    file creation date
//      {camera} {lens} {iso} {aperture} {shutter} {focal} {rating}
//      {ext}                                original extension, no dot
//      {{ and }}                            literal braces
//
//  Rules: a missing value renders empty; then runs of `_`, `-` and
//  spaces collapse to one and are trimmed at the ends; `/` and `:` become
//  `-`. The case change applies to the stem. The extension is never
//  changed.
//

import Foundation

public enum NameCase: String, Sendable, Hashable, CaseIterable, Codable {
    case keep, lower, upper, title
}

public enum RenameTemplateError: Error, Sendable, Equatable {
    /// `{foo}` — name and character offsets of the whole `{…}`.
    case unknownToken(String, Range<Int>)
    /// `{counter:abc}`, `{date:}` …
    case invalidArgument(token: String, argument: String, Range<Int>)
    /// `{` with no `}` (offset of the `{`).
    case unclosedBrace(at: Int)
    case empty
}

/// Why a row can't take its new name as is.
public enum RenameIssue: Sendable, Hashable {
    /// An earlier item in the batch already gets this name.
    case duplicateInBatch
    /// A file that is not part of the batch already has this name.
    case existsOnDisk
    /// The template rendered nothing for this item.
    case emptyName
}

public struct RenamePlanRow: Sendable, Hashable {
    public let source: URL
    /// New file name, original extension included.
    public let newName: String
    public var destination: URL { source.deletingLastPathComponent().appendingPathComponent(newName) }
    /// Same name as now (nothing to do).
    public let isUnchanged: Bool
    public let issue: RenameIssue?
}

public struct RenameTemplate: Sendable, Hashable {

    public enum DateSource: Sendable, Hashable {
        /// DateTimeOriginal, else the file's creation date.
        case taken
        /// The file's creation date (modification date if missing).
        case file
    }

    public enum Part: Sendable, Hashable {
        case literal(String)
        case name(NameCase)
        case counter(width: Int)
        case date(format: String, source: DateSource)
        case camera, lens, iso, aperture, shutter, focal, rating
        case ext
    }

    /// Chip list for the Tokens… popover.
    public static let tokens: [String] = [
        "{name}", "{yyyy}", "{MM}", "{dd}", "{yyyy-MM-dd}", "{HH-mm-ss}",
        "{counter}", "{counter:000}", "{counter:0000}",
        "{camera}", "{lens}", "{iso}", "{aperture}", "{shutter}", "{focal}", "{rating}",
        "{date:yyyyMMdd}", "{filedate:yyyy-MM-dd}", "{ext}",
    ]

    public let source: String
    public let parts: [Part]
    /// First counter value.
    public var counterStart: Int
    /// Case change for the whole stem.
    public var nameCase: NameCase

    /// Whether rendering needs `PhotoInfo` (lets callers skip the read).
    public var needsPhotoInfo: Bool {
        parts.contains {
            switch $0 {
            case .camera, .lens, .iso, .aperture, .shutter, .focal: return true
            case .date(_, .taken): return true
            default: return false
            }
        }
    }

    public init(parsing template: String, counterStart: Int = 1, nameCase: NameCase = .keep) throws {
        self.source = template
        self.counterStart = counterStart
        self.nameCase = nameCase
        self.parts = try Self.parse(template)
    }

    // MARK: - Parse

    private static let dateLetters = Set("yMdHhmsSaEkK")

    static func parse(_ template: String) throws -> [Part] {
        guard !template.isEmpty else { throw RenameTemplateError.empty }
        let chars = Array(template)
        var parts: [Part] = []
        var literal = ""
        var i = 0
        func flush() {
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "{", i + 1 < chars.count, chars[i + 1] == "{" {
                literal.append("{"); i += 2; continue
            }
            if c == "}", i + 1 < chars.count, chars[i + 1] == "}" {
                literal.append("}"); i += 2; continue
            }
            guard c == "{" else { literal.append(c); i += 1; continue }
            guard let close = chars[(i + 1)...].firstIndex(of: "}") else {
                throw RenameTemplateError.unclosedBrace(at: i)
            }
            let body = String(chars[(i + 1)..<close])
            let range = i..<(close + 1)
            flush()
            parts.append(try token(body, range: range))
            i = close + 1
        }
        flush()
        return parts
    }

    private static func token(_ body: String, range: Range<Int>) throws -> Part {
        let name: String
        let arg: String?
        if let colon = body.firstIndex(of: ":") {
            name = String(body[..<colon])
            arg = String(body[body.index(after: colon)...])
        } else {
            name = body
            arg = nil
        }
        func bad() -> RenameTemplateError {
            .invalidArgument(token: name, argument: arg ?? "", range)
        }
        switch (name, arg) {
        case ("name", nil): return .name(.keep)
        case ("name", let a?):
            guard let c = NameCase(rawValue: a.lowercased()), c != .keep else { throw bad() }
            return .name(c)
        case ("counter", nil): return .counter(width: 0)
        case ("counter", let a?):
            if !a.isEmpty, a.allSatisfy({ $0 == "0" }) { return .counter(width: a.count) }
            if let n = Int(a), (1...9).contains(n) { return .counter(width: n) }
            throw bad()
        case ("date", let a?), ("filedate", let a?):
            guard !a.isEmpty, a.contains(where: { dateLetters.contains($0) }),
                  a.allSatisfy({ !$0.isLetter || dateLetters.contains($0) }) else { throw bad() }
            return .date(format: a, source: name == "date" ? .taken : .file)
        case ("yyyy", nil), ("MM", nil), ("dd", nil), ("yyyy-MM-dd", nil), ("HH-mm-ss", nil):
            return .date(format: name, source: .taken)
        case ("camera", nil): return .camera
        case ("lens", nil): return .lens
        case ("iso", nil): return .iso
        case ("aperture", nil): return .aperture
        case ("shutter", nil): return .shutter
        case ("focal", nil): return .focal
        case ("rating", nil): return .rating
        case ("ext", nil): return .ext
        default:
            throw RenameTemplateError.unknownToken(name, range)
        }
    }

    // MARK: - Render

    /// New stem (no extension) for one file. `counter` is the value to
    /// print (callers add `counterStart`). `fileDate` backs `{filedate}`
    /// and the taken-date fallback.
    public func render(info: PhotoInfo?, originalStem: String, counter: Int, case nameCase: NameCase,
                       fileDate: Date? = nil, rating: Int? = nil, fileExtension: String = "") -> String {
        var cache = FormatterCache()
        return render(info: info, originalStem: originalStem, counter: counter, case: nameCase,
                      fileDate: fileDate, rating: rating, fileExtension: fileExtension, cache: &cache)
    }

    private func render(info: PhotoInfo?, originalStem: String, counter: Int, case nameCase: NameCase,
                        fileDate: Date?, rating: Int?, fileExtension: String,
                        cache: inout FormatterCache) -> String {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let s): out += s
            case .name(let c): out += Self.apply(c, to: originalStem)
            case .counter(let width):
                let digits = String(abs(counter))
                let padded = digits.count < width
                    ? String(repeating: "0", count: width - digits.count) + digits : digits
                out += (counter < 0 ? "-" : "") + padded
            case .date(let format, let source):
                let date: Date?
                let zone: TimeZone
                switch source {
                case .taken:
                    date = info?.dateTaken ?? fileDate
                    zone = info?.dateTaken != nil ? (info?.dateTakenTimeZone ?? .current) : .current
                case .file:
                    date = fileDate
                    zone = .current
                }
                if let date { out += cache.string(date, format: format, zone: zone) }
            case .camera: out += info?.camera ?? ""
            case .lens: out += info?.lens ?? ""
            case .iso: out += info?.iso.map(String.init) ?? ""
            case .aperture: out += info?.aperture.map { Self.trim($0) } ?? ""
            case .shutter:
                if let s = info?.shutter {
                    out += s < 0.3 ? "1/\(Int((1 / s).rounded()))" : Self.trim(s)
                }
            case .focal: out += info?.focal.map { Self.trim($0) } ?? ""
            case .rating: out += rating.map(String.init) ?? ""
            case .ext: out += fileExtension
            }
        }
        let clean = Self.apply(nameCase, to: Self.sanitize(out))
        return Self.fit(clean, extension: fileExtension)
    }

    // MARK: - Batch plan

    /// Render every URL (counter in list order from `counterStart`) and
    /// flag clashes: with an earlier row of the batch, or with a file on
    /// disk that isn't itself being renamed. Names that stay the same
    /// claim their slot first. Case-insensitive volumes compare folded.
    public func plan(
        for urls: [URL],
        info: (URL) -> PhotoInfo? = { try? PhotoInfo.readSync($0) },
        rating: (URL) -> Int? = { FileAttributes.rating(at: $0) },
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [RenamePlanRow] {
        let wantsInfo = needsPhotoInfo
        let wantsRating = parts.contains(.rating)
        var cache = FormatterCache()
        var rendered: [(url: URL, name: String, stem: String)] = []
        rendered.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            let ext = url.pathExtension
            let oldStem = url.deletingPathExtension().lastPathComponent
            let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let stem = render(info: wantsInfo ? info(url) : nil, originalStem: oldStem,
                              counter: counterStart + i, case: nameCase,
                              fileDate: dates?.creationDate ?? dates?.contentModificationDate,
                              rating: wantsRating ? rating(url) : nil, fileExtension: ext,
                              cache: &cache)
            rendered.append((url, ext.isEmpty ? stem : stem + "." + ext, stem))
        }

        let sourceKeys = Set(CanonicalPath.keys(urls))
        let destinations = rendered.map {
            $0.url.deletingLastPathComponent().appendingPathComponent($0.name)
        }
        let destKeys = CanonicalPath.keys(destinations)
        var claimed = Set<String>()
        var unchanged = [Bool](repeating: false, count: urls.count)
        // Pass 1: files that keep their exact name hold on to it.
        for i in rendered.indices where rendered[i].name == urls[i].lastPathComponent {
            unchanged[i] = true
            claimed.insert(destKeys[i])
        }
        var rows: [RenamePlanRow] = []
        rows.reserveCapacity(urls.count)
        for i in rendered.indices {
            let r = rendered[i]
            var issue: RenameIssue?
            if r.stem.isEmpty {
                issue = .emptyName
            } else if !unchanged[i] {
                let key = destKeys[i]
                if claimed.contains(key) {
                    issue = .duplicateInBatch
                } else if fileExists(destinations[i]), !sourceKeys.contains(key) {
                    issue = .existsOnDisk
                }
                claimed.insert(key)
            }
            rows.append(RenamePlanRow(source: r.url, newName: r.name,
                                      isUnchanged: unchanged[i], issue: issue))
        }
        return rows
    }

    /// `(source, new file name)` for every URL — the Batch window's
    /// preview list. Use `plan(for:)` for clash flags.
    public func preview(for urls: [URL]) -> [(URL, String)] {
        plan(for: urls).map { ($0.source, $0.newName) }
    }

    // MARK: - Helpers

    /// `/` `:` → `-`; control characters dropped; runs of `_` `-`
    /// space collapse to their first character; trimmed at the ends.
    static func sanitize(_ s: String) -> String {
        var out = ""
        var lastWasSeparator = false
        for ch in s {
            var c = ch
            if c == "/" || c == ":" { c = "-" }
            if c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { continue }
            let isSep = c == "_" || c == "-" || c == " "
            if isSep && lastWasSeparator { continue }
            out.append(c)
            lastWasSeparator = isSep
        }
        let seps = CharacterSet(charactersIn: "_- ")
        return out.trimmingCharacters(in: seps)
    }

    static func apply(_ c: NameCase, to s: String) -> String {
        switch c {
        case .keep: return s
        case .lower: return s.lowercased()
        case .upper: return s.uppercased()
        case .title: return s.capitalized
        }
    }

    /// Keep stem + "." + extension within 255 UTF-8 bytes.
    static func fit(_ stem: String, extension ext: String) -> String {
        let budget = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        guard stem.utf8.count > budget else { return stem }
        var s = stem
        while s.utf8.count > budget { s.removeLast() }
        return s
    }

    private static func trim(_ v: Double) -> String {
        var s = String(format: "%.1f", v)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// DateFormatter is costly to build and not Sendable: one per format
    /// and zone for the length of a render / plan call.
    private struct FormatterCache {
        private var formatters: [String: DateFormatter] = [:]
        mutating func string(_ date: Date, format: String, zone: TimeZone) -> String {
            let key = "\(zone.identifier)|\(format)"
            if let f = formatters[key] { return f.string(from: date) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = zone
            f.dateFormat = format
            formatters[key] = f
            return f.string(from: date)
        }
    }
}

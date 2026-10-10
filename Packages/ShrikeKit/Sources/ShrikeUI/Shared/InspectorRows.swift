//
//  InspectorRows.swift
//  ShrikeUI
//
//  The inspector's row table, shared by the viewer's
//  inspector panel and the Browser's inspector pane. Pure: values come
//  from `PhotoInfo` and the file's size. A row whose value
//  is missing is left out (no "—" rows).
//

import Foundation
import ShrikeCore

/// One "Label  value" line.
public struct InspectorRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Everything the inspector shows about one file.
public struct InspectorFacts: Equatable, Sendable {
    public var file: [InspectorRow] = []
    public var capture: [InspectorRow] = []
    /// "45.4371° N, 12.3327° E" — signed by the GPS Ref tags.
    public var location: String?
    /// The GPS behind `location` (the "Show in Maps" link).
    public var coordinate: PhotoInfo.Coordinate?
    public init() {}
}

public enum InspectorRows {

    /// All sections for `url`. `info` is nil until (or unless) the header
    /// has been read; the file rows that need it are then left out.
    public static func facts(url: URL, fileSize: Int64?, info: PhotoInfo?) -> InspectorFacts {
        var facts = InspectorFacts()
        facts.file = file(url: url, fileSize: fileSize, info: info)
        if let info {
            facts.capture = capture(info)
            facts.location = location(info)
            facts.coordinate = info.gps
        }
        return facts
    }

    /// Name · Folder · Size · Dimensions · Type · Colour profile.
    public static func file(url: URL, fileSize: Int64?, info: PhotoInfo?) -> [InspectorRow] {
        var rows = [InspectorRow("Name", url.lastPathComponent)]
        let folder = url.deletingLastPathComponent().lastPathComponent
        if !folder.isEmpty { rows.append(InspectorRow("Folder", folder)) }
        if let fileSize {
            rows.append(InspectorRow("Size", ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))
        }
        if let size = info?.pixelSize, size.width > 0, size.height > 0 {
            rows.append(InspectorRow("Dimensions", PhotoInfo.Format.dimensions(size)))
        }
        if let type = info?.typeName, !type.isEmpty { rows.append(InspectorRow("Type", type)) }
        if let profile = info?.colorProfileName, !profile.isEmpty {
            rows.append(InspectorRow("Colour profile", profile))
        }
        return rows
    }

    /// Date taken · Camera · Lens · Aperture · Shutter · ISO · Focal
    /// length · Exposure bias · Flash · White balance.
    public static func capture(_ info: PhotoInfo, locale: Locale = .current) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        if let date = info.dateTaken {
            rows.append(InspectorRow("Date taken", dateTaken(date, zone: info.dateTakenTimeZone, locale: locale)))
        }
        if let camera = info.camera { rows.append(InspectorRow("Camera", camera)) }
        if let lens = info.lens?.trimmingCharacters(in: .whitespaces), !lens.isEmpty {
            rows.append(InspectorRow("Lens", lens))
        }
        if let f = info.aperture, f > 0 { rows.append(InspectorRow("Aperture", PhotoInfo.Format.aperture(f))) }
        if let s = info.shutter, s > 0 { rows.append(InspectorRow("Shutter", PhotoInfo.Format.shutter(s))) }
        if let iso = info.iso, iso > 0 { rows.append(InspectorRow("ISO", "\(iso)")) }
        if let mm = info.focal, mm > 0 {
            rows.append(InspectorRow("Focal length", PhotoInfo.Format.focal(mm, equivalent: info.focal35)))
        }
        if let ev = info.exposureBias { rows.append(InspectorRow("Exposure bias", PhotoInfo.Format.exposureBias(ev))) }
        if let fired = info.flashFired { rows.append(InspectorRow("Flash", fired ? "Fired" : "Did not fire")) }
        if let auto = info.whiteBalanceAuto { rows.append(InspectorRow("White balance", auto ? "Auto" : "Manual")) }
        return rows
    }

    /// Sign and letter come from the Ref tags (bug fix: south and west
    /// were shown as north and east).
    public static func location(_ info: PhotoInfo) -> String? {
        info.gps.map(PhotoInfo.Format.coordinate)
    }

    /// "25 Sep 2026 at 14:02:31" — medium date, medium time, in the zone
    /// the camera recorded (OffsetTimeOriginal) when there is one.
    public static func dateTaken(_ date: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    /// Edits row: "Original kept since 25 Sep 2026".
    public static func originalKept(since date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Original kept since " + f.string(from: date)
    }
}

//
//  InspectorRows.swift
//  ShrikeUI
//
//  The inspector's row table, shared by the viewer's
//  inspector panel and the Browser's inspector pane. Pure: values come
//  from `PhotoInfo` and the file's resource values. The
//  first four File rows show "—" when empty; other empty rows are left out.
//

import Foundation
import SwiftUI
import ShrikeCore
import UniformTypeIdentifiers

/// One "Label  value" line. `tooltip` is the longer form shown on hover
/// (Date taken / Modified with seconds, Dimensions with megapixels).
public struct InspectorRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public var tooltip: String?
    public var id: String { label }
    public init(_ label: String, _ value: String, tooltip: String? = nil) {
        self.label = label
        self.value = value
        self.tooltip = tooltip
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

/// One date-and-time format for the info panel:
/// `Nov 10, 2026 at 11:04 PM` (medium date, short time, the Mac's locale);
/// the tooltip carries the seconds.
public enum InspectorFormat {
    public static func dateTime(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        format(date, zone: zone, locale: locale, time: .short)
    }

    /// The tooltip form: the same with seconds.
    public static func dateTimeWithSeconds(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        format(date, zone: zone, locale: locale, time: .medium)
    }

    private static func format(_ date: Date, zone: TimeZone, locale: Locale, time: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateStyle = .medium
        f.timeStyle = time
        return f.string(from: date)
    }
}

/// The inputs of the File section, the same for both panels.
public struct InspectorFileInput: Equatable, Sendable {
    public var type: UTType?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var fileSize: Int64?
    /// Browser, 2+ selected: the sizes added up ("Total size").
    public var totalSize: Int64?
    public var modified: Date?
    public var colorProfile: String?
    /// Viewer only: the folder's name.
    public var folder: String?
    public init(type: UTType? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, fileSize: Int64? = nil,
                totalSize: Int64? = nil, modified: Date? = nil, colorProfile: String? = nil, folder: String? = nil) {
        self.type = type
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.totalSize = totalSize
        self.modified = modified
        self.colorProfile = colorProfile
        self.folder = folder
    }
}

public enum InspectorRows {

    /// The value of an empty row among the first four (the panel does not jump).
    public static let emptyValue = "—"

    /// All sections for `url`. `info` is nil until (or unless) the header
    /// has been read. `modified` / `type` come from the file's resource
    /// values (the type falls back to the name extension).
    public static func facts(url: URL, fileSize: Int64?, info: PhotoInfo?,
                             modified: Date? = nil, type: UTType? = nil) -> InspectorFacts {
        var facts = InspectorFacts()
        facts.file = file(url: url, fileSize: fileSize, info: info, modified: modified, type: type)
        if let info {
            facts.capture = capture(info)
            facts.location = location(info)
            facts.coordinate = info.gps
        }
        return facts
    }

    /// The viewer's File rows: Type · Dimensions · Size · Modified ·
    /// Color profile · Folder.
    public static func file(url: URL, fileSize: Int64?, info: PhotoInfo?,
                            modified: Date? = nil, type: UTType? = nil) -> [InspectorRow] {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return fileRows(InspectorFileInput(
            type: type ?? UTType(filenameExtension: url.pathExtension),
            pixelWidth: info?.pixelWidth, pixelHeight: info?.pixelHeight,
            fileSize: fileSize, modified: modified,
            colorProfile: info?.colorProfileName,
            folder: folder.isEmpty ? nil : folder))
    }

    /// The File section of both panels, in their display order. The
    /// first four rows show `—` when empty; Color profile and Folder are
    /// left out.
    public static func fileRows(_ input: InspectorFileInput, locale: Locale = .current) -> [InspectorRow] {
        var rows = [InspectorRow("Type", typeLabel(input.type))]
        if let w = input.pixelWidth, let h = input.pixelHeight, w > 0, h > 0 {
            let size = CGSize(width: w, height: h)
            rows.append(InspectorRow("Dimensions", "\(w) × \(h)", tooltip: PhotoInfo.Format.dimensions(size)))
        } else {
            rows.append(InspectorRow("Dimensions", emptyValue))
        }
        if let total = input.totalSize {
            rows.append(InspectorRow("Total size", FileSizeText.string(total)))
        } else if let size = input.fileSize {
            rows.append(InspectorRow("Size", FileSizeText.string(size)))
        } else {
            rows.append(InspectorRow("Size", emptyValue))
        }
        if let date = input.modified {
            rows.append(InspectorRow("Modified", InspectorFormat.dateTime(date, locale: locale),
                                     tooltip: InspectorFormat.dateTimeWithSeconds(date, locale: locale)))
        } else {
            rows.append(InspectorRow("Modified", emptyValue))
        }
        if let profile = input.colorProfile, !profile.isEmpty {
            rows.append(InspectorRow("Color profile", profile))
        }
        if let folder = input.folder { rows.append(InspectorRow("Folder", folder)) }
        return rows
    }

    /// "JPEG image" — the system's name of the type; `—` when unknown or mixed.
    public static func typeLabel(_ type: UTType?) -> String {
        guard let type else { return emptyValue }
        return type.localizedDescription ?? type.identifier
    }

    /// Date taken · Camera · Lens · Aperture · Shutter · ISO · Focal
    /// length · Exposure bias · Flash · White balance.
    public static func capture(_ info: PhotoInfo, locale: Locale = .current) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        if let date = info.dateTaken {
            rows.append(InspectorRow("Date taken", dateTaken(date, zone: info.dateTakenTimeZone, locale: locale),
                                     tooltip: InspectorFormat.dateTimeWithSeconds(date, zone: info.dateTakenTimeZone,
                                                                                  locale: locale)))
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

    /// Date taken in the zone the camera recorded (OffsetTimeOriginal) when
    /// there is one, in the one panel format (`InspectorFormat.dateTime`).
    public static func dateTaken(_ date: Date, zone: TimeZone, locale: Locale = .current) -> String {
        InspectorFormat.dateTime(date, zone: zone, locale: locale)
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

// MARK: - Narrow panel forms

public extension InspectorRows {

    /// Below this panel width the long forms give way to short ones.
    static let compactWidth: CGFloat = 300

    static func isCompact(width: CGFloat) -> Bool { width < compactWidth }

    /// The short form of a row at a narrow width: Dimensions drops " (17.9 MP)"
    /// (the full value goes to the tooltip). Dates keep the one panel format
    /// Other rows are unchanged (they wrap instead).
    static func compactValue(label: String, value: String) -> String {
        switch label {
        case "Dimensions":
            return value.replacingOccurrences(of: #"\s*\([^)]*MP\)"#, with: "", options: .regularExpression)
        default:
            return value
        }
    }
}

// MARK: - Shared SwiftUI pieces: the viewer and the Browser inspector use these

/// One set of tokens for both inspectors.
public enum InspectorLayout {
    public static let headerFontSize: CGFloat = 13
    public static let rowGap: CGFloat = 4
    public static let sectionGap: CGFloat = 16
    public static let valueLineLimit = 2

    /// The Browser info panel's surface: the page-background tone in a dark
    /// window (as before); the window colour in a light one, where the page
    /// tone is a dim grey block.
    public static var browserPaneBackground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .underPageBackgroundColor : .windowBackgroundColor
        }
    }

    /// Row labels: the system's secondary colour in a dark window; in a
    /// light one it is only 3.9:1 on the window colour, so the label is
    /// primary at 70 %.
    public static var rowLabelColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .secondaryLabelColor : NSColor.labelColor.withAlphaComponent(0.7)
        }
    }
}

/// A section header: 13 pt semibold, primary colour.
struct InspectorSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: InspectorLayout.headerFontSize, weight: .semibold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One "label  value" row: the label 12 pt secondary, the value 12 pt
/// primary right-aligned to the shared trailing edge; a long value wraps to
/// two lines and then tail-truncates (never the middle).
struct InspectorRowView: View {
    let label: String
    let value: String
    var tooltip: String?
    var compact = false
    var isSelectable = true
    @Environment(\.inspectorCompact) private var envCompact

    var body: some View {
        let shown = (compact || envCompact) ? InspectorRows.compactValue(label: label, value: value) : value
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: InspectorStyle.smallFontSize))
                    .foregroundStyle(Color(nsColor: InspectorLayout.rowLabelColor))
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(shown)
                .font(.system(size: InspectorStyle.smallFontSize))
                .foregroundStyle(.primary)
                .lineLimit(InspectorLayout.valueLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(tooltip ?? (shown == value ? "" : value))
        }
    }
}

private struct InspectorCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while the panel is narrower than `InspectorRows.compactWidth`.
    var inspectorCompact: Bool {
        get { self[InspectorCompactKey.self] }
        set { self[InspectorCompactKey.self] = newValue }
    }
}

private struct InspectorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports the panel width to `content` as "compact or not".
struct InspectorCompactReader<Content: View>: View {
    @State private var width: CGFloat = 400
    let content: (Bool) -> Content
    var body: some View {
        content(InspectorRows.isCompact(width: width))
            .environment(\.inspectorCompact, InspectorRows.isCompact(width: width))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}


// MARK: - Shared pieces of both panels

/// The title line: the file name (13 pt semibold, 1-2 lines, selectable)
/// and the "Also: …" line only when a pair exists. Nothing is reserved, so
/// a short name leaves no gap.
struct InspectorTitleBlock: View {
    let name: String
    let also: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: InspectorLayout.headerFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            if let also {
                Text(also)
                    .font(.system(size: InspectorStyle.smallFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Five stars (one adjustable VoiceOver element) and, 6 pt to their right,
/// the `Clear` link when `showsClear`. `rating` nil = mixed (counts as 0).
struct InspectorStarsRow: View {
    let rating: Int?
    let showsClear: Bool
    let onRate: (Int) -> Void

    /// Clear shows when rated; in the browser also when the selection's
    /// ratings are mixed.
    static func showsClear(rating: Int?, mixed: Bool) -> Bool { (rating ?? 0) > 0 || mixed }

    var body: some View {
        let now = rating ?? 0
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { i in
                    let filled = now >= i
                    Button { onRate(i) } label: {
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.system(size: InspectorStyle.starSize))
                            .foregroundStyle(filled ? Color(nsColor: InspectorStyle.filledStarColor) : Color.secondary)
                            .frame(width: InspectorStyle.starHitSize, height: InspectorStyle.starHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(i) star\(i == 1 ? "" : "s")")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(now == 0 ? "No stars" : "\(now) of 5 stars")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onRate(min(5, now + 1))
                case .decrement: onRate(max(0, now - 1))
                @unknown default: break
                }
            }
            if showsClear {
                InspectorClearLink { onRate(0) }
                    .padding(.leading, 6)
            }
        }
    }
}

/// The `Flagged` checkbox of both panels.
struct InspectorFlagToggle: View {
    let isOn: Bool
    let onChange: (Bool) -> Void
    var body: some View {
        Toggle("Flagged", isOn: Binding(get: { isOn }, set: { onChange($0) }))
            .toggleStyle(.checkbox)
            .font(.system(size: InspectorStyle.smallFontSize))
    }
}

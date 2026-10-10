//
//  CompareModel.swift
//  ShrikeUI
//
//  The pure parts of the Compare window: which images a
//  source gives, where the panes go, how Lock shares zoom and pan, the
//  key lookup and the pane footer. No AppKit windows here, so all of it
//  is unit-testable.
//

import AppKit
import ShrikeCore

// MARK: - Sources

/// What Compare opens with: the list the panes move through (the source
/// folder list) and the list index each pane starts on, in pane order.
public struct CompareRequest: Equatable, Sendable {
    public let list: [ImageGroup]
    public let shown: [Int]
    /// More than 4 were selected: only the first 4 show, with a toast.
    public let truncated: Bool
}

public enum CompareSources {

    public static let maxPanes = 4

    /// "Compare shows up to 4 images. Showing the first 4.".
    public static let truncatedToast = "Compare shows up to 4 images. Showing the first 4."

    /// Browser: 2–4 selected = those; 1 = it and the next; over 4 = the
    /// first 4. `selected` are indices into `list` (the visible items).
    public static func fromBrowser(list: [ImageGroup], selected: [Int]) -> CompareRequest? {
        let valid = selected.filter { list.indices.contains($0) }.sorted()
        switch valid.count {
        case 0:
            return nil
        case 1:
            return pair(list: list, index: valid[0])
        default:
            return CompareRequest(list: list, shown: Array(valid.prefix(maxPanes)),
                                  truncated: valid.count > maxPanes)
        }
    }

    /// Viewer: the displayed image and the next.
    public static func fromViewer(list: [ImageGroup], displayed: Int) -> CompareRequest? {
        guard list.indices.contains(displayed) else { return nil }
        return pair(list: list, index: displayed)
    }

    /// `index` and the next one; the one before at the end of the list.
    private static func pair(list: [ImageGroup], index: Int) -> CompareRequest? {
        guard list.count >= 2 else { return nil }
        let other = index + 1 < list.count ? index + 1 : index - 1
        return CompareRequest(list: list, shown: [index, other].sorted(), truncated: false)
    }
}

// MARK: - Layout (2 side by side, 3 columns, 2 × 2)

public enum CompareLayout {

    /// 1 pt `separatorColor` gutters.
    public static let gutter: CGFloat = 1

    public static func grid(for count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (2, 1)
        case 3: return (3, 1)
        default: return (2, 2)
        }
    }

    /// Pane frames in pane order (left to right, top row first), in a
    /// non-flipped view of `bounds`. Edges are rounded to whole points.
    public static func frames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let (columns, rows) = grid(for: count)
        func edge(_ i: Int, of n: Int, length: CGFloat) -> CGFloat {
            ((length - CGFloat(n - 1) * gutter) * CGFloat(i) / CGFloat(n) + CGFloat(i) * gutter).rounded()
        }
        return (0..<count).map { i in
            let column = i % columns, row = i / columns
            let x0 = edge(column, of: columns, length: bounds.width)
            // edge(n) is the length plus one gutter: every pane ends a
            // gutter before the next pane's start.
            let x1 = edge(column + 1, of: columns, length: bounds.width) - gutter
            let y0 = edge(row, of: rows, length: bounds.height)
            let y1 = edge(row + 1, of: rows, length: bounds.height) - gutter
            // Row 0 is the top row.
            return CGRect(x: bounds.minX + x0, y: bounds.maxY - y1,
                          width: max(0, x1 - x0), height: max(0, y1 - y0))
        }
    }
}

// MARK: - Lock (Match %)

/// Locked panes share the zoom (same image pixels per screen pixel) and
/// the relative position: the image point at each pane's centre is the
/// same fraction of its image.
public enum CompareLock {

    /// The image point under the view centre, as a fraction (0…1 on each
    /// axis) of the drawn image rect.
    public static func relativeCentre(imageRect: CGRect, viewBounds: CGRect) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (viewBounds.midX - imageRect.minX) / imageRect.width,
                       y: (viewBounds.midY - imageRect.minY) / imageRect.height)
    }

    /// How far to move the pan so that `relative` lands on the centre.
    public static func panDelta(toCentre relative: CGPoint, imageRect: CGRect, viewBounds: CGRect) -> CGPoint {
        let target = CGPoint(x: viewBounds.midX - relative.x * imageRect.width,
                             y: viewBounds.midY - relative.y * imageRect.height)
        return CGPoint(x: target.x - imageRect.minX, y: target.y - imageRect.minY)
    }
}

// MARK: - Keys

/// The Compare key lookup: the `.compare` rows of `ShortcutTable`, plus
/// the rule "⇧ = all panes" for the rating and flag keys.
public enum CompareKeyMap {

    public struct Hit: Equatable, Sendable {
        public let command: ShrikeCommand
        public let allPanes: Bool
    }

    /// `unshiftedKey` is the key without ⇧ (⇧1 reads "!" on most
    /// layouts); nil = `snapshot.key`.
    public static func hit(for snapshot: KeyEventSnapshot, unshiftedKey: String? = nil,
                           preset: ShortcutPreset) -> Hit? {
        if let command = ShortcutTable.command(for: snapshot, context: .compare, preset: preset) {
            return Hit(command: command, allPanes: false)
        }
        guard snapshot.flags.contains(.shift) else { return nil }
        let plain = KeyEventSnapshot(key: (unshiftedKey ?? snapshot.key).lowercased(),
                                     modifiers: snapshot.flags.subtracting(.shift))
        guard let command = ShortcutTable.command(for: plain, context: .compare, preset: preset),
              command.isCulling else { return nil }
        return Hit(command: command, allPanes: true)
    }
}

extension ShrikeCommand {
    /// Rating and flag commands.
    var isCulling: Bool {
        switch self {
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .toggleFlag: return true
        default: return false
        }
    }

    /// Stars for a rating command.
    var ratingValue: Int? {
        switch self {
        case .rate0: return 0
        case .rate1: return 1
        case .rate2: return 2
        case .rate3: return 3
        case .rate4: return 4
        case .rate5: return 5
        default: return nil
        }
    }
}

// MARK: - Footer

public enum CompareFooter {

    /// 24 pt, overlay material, 11 pt.
    public static let height: CGFloat = 24
    public static let fontSize: CGFloat = 11

    /// "DSC_0042.jpg  ★★★ ⚑   6000 × 4000   ƒ/2.8  1/250 s  ISO 200".
    /// Missing parts drop out with their spacing.
    public static func text(name: String, rating: Int, flagged: Bool, pixelSize: CGSize?,
                            aperture: Double?, shutter: Double?, iso: Int?) -> String {
        var out = name
        var marks: [String] = []
        if rating > 0 { marks.append(String(repeating: "★", count: min(5, rating))) }
        if flagged { marks.append("⚑") }
        if !marks.isEmpty { out += "  " + marks.joined(separator: " ") }
        if let size = pixelSize, size.width > 0, size.height > 0 {
            out += "   \(Int(size.width)) × \(Int(size.height))"
        }
        var exposure: [String] = []
        if let aperture, aperture > 0 { exposure.append(PhotoInfo.Format.aperture(aperture)) }
        if let shutter, shutter > 0 { exposure.append(PhotoInfo.Format.shutter(shutter)) }
        if let iso, iso > 0 { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { out += "   " + exposure.joined(separator: "  ") }
        return out
    }

    /// "Shrike can't open “x.jpg”.".
    public static func errorText(_ name: String) -> String { "Shrike can't open “\(name)”." }
}

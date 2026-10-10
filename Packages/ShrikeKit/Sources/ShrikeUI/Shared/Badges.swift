//
//  Badges.swift
//  ShrikeUI
//
//  Small marks drawn on cells and in the position pill:
//  stars, flag, tag dots, RAW chip, `livephoto`, `pencil`. Only set values
//  are drawn — nothing for rating 0, no flag, no tags.
//
//  The helpers are nonisolated on purpose: AppKit may run an image's
//  drawing handler on any thread, so the handlers never touch main-actor
//  state. Colours are resolved by the caller.
//

import AppKit
import ShrikeIO

/// What a cell or the pill shows for one list item.
public struct ItemBadges: Equatable, Sendable {
    public var rating: Int
    public var flagged: Bool
    /// Finder tags with their colours.
    public var tags: [FinderTag]
    public var hasRAW: Bool
    public var isLivePhoto: Bool
    /// Shrike changed the file and kept the original.
    public var edited: Bool

    public init(rating: Int = 0, flagged: Bool = false, tags: [FinderTag] = [],
                hasRAW: Bool = false, isLivePhoto: Bool = false, edited: Bool = false) {
        self.rating = rating
        self.flagged = flagged
        self.tags = tags
        self.hasRAW = hasRAW
        self.isLivePhoto = isLivePhoto
        self.edited = edited
    }
}

/// The badge facts that are not in `MetadataStore`: Finder tags (on the
/// file) and the pencil (backup chain).
public struct FileBadgeExtras: Equatable, Sendable {
    public var tags: [FinderTag]
    public var edited: Bool
    public init(tags: [FinderTag] = [], edited: Bool = false) {
        self.tags = tags
        self.edited = edited
    }
}

public enum Badges {

    /// `accent.rating` #F5C518 and `accent.flag` #FF9500.
    public static let ratingColor = NSColor(srgbRed: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255, alpha: 1)
    public static let flagColor = NSColor(srgbRed: 1, green: 0x95 / 255, blue: 0, alpha: 1)

    /// Dots for a tag list: one per distinct colour in tag order, then one
    /// grey dot if any tag has no colour; at most 3. `.none` in the
    /// result stands for that grey "name-only" dot.
    public static func dotColors(_ tags: [FinderTag]) -> [FinderTagColor] {
        var out: [FinderTagColor] = []
        for tag in tags where tag.color != .none && !out.contains(tag.color) {
            out.append(tag.color)
        }
        if tags.contains(where: { $0.color == .none }) { out.append(.none) }
        return Array(out.prefix(3))
    }

    /// The fill for one dot (grey for name-only tags).
    @MainActor
    public static func dotFill(_ color: FinderTagColor) -> NSColor {
        color.nsColor ?? .systemGray
    }

    /// "Red, Client" — tag names for VoiceOver.
    public static func tagSpeech(_ tags: [FinderTag]) -> String {
        tags.map(\.name).joined(separator: ", ")
    }

    /// Stars text: "★★★" for 3, "" for 0 (no empty stars).
    public static func stars(_ rating: Int) -> String {
        String(repeating: "★", count: max(0, min(5, rating)))
    }

    /// A row of `diameter` circles, `gap` apart.
    public static func tagDotsImage(_ fills: [NSColor], diameter: CGFloat = 7, gap: CGFloat = 2) -> NSImage? {
        guard !fills.isEmpty else { return nil }
        let width = CGFloat(fills.count) * diameter + CGFloat(fills.count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: diameter), flipped: false) { _ in
            for (i, fill) in fills.enumerated() {
                fill.setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * (diameter + gap), y: 0,
                                            width: diameter, height: diameter)).fill()
            }
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    /// "RAW" in a 1 pt outline, corner 3, padding 3/1.
    public static func rawChipImage(fontSize: CGFloat = 9, height: CGFloat? = nil, color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = NSAttributedString(string: "RAW", attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()
        let h = height ?? ceil(textSize.height + 2)
        let size = NSSize(width: ceil(textSize.width + 6), height: h)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
            text.draw(at: NSPoint(x: 3, y: (h - textSize.height) / 2))
            return true
        }
    }

    /// An SF Symbol in one colour.
    public static func symbol(_ name: String, pointSize: CGFloat, color: NSColor,
                              weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// 1 pt shadow, black 60 %, blur 1 — for marks drawn on a thumbnail.
    @MainActor public static func applyThumbnailShadow(to view: NSView) {
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.6
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
        view.layer?.shadowRadius = 1
    }
}

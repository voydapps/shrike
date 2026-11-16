//
//  CropKeyGeometry.swift
//  ShrikeUI
//
//  Keyboard control of the crop frame. All the math is
//  here, in whole IMAGE pixels (origin top-left, +y down), so a step feels
//  the same at any zoom. The overlay only turns key events into
//  `CropKeyCommand`s and the results into a frame.
//

import AppKit

/// What one key press asks of the crop frame.
enum CropKeyCommand: Equatable {
    /// Move the frame `steps` pixels in the direction (dx, dy) (each -1, 0 or 1).
    case move(dx: Int, dy: Int, steps: Int)
    /// Move edges outward (+1) or inward (-1) by `steps` pixels.
    case resize(CropKeyGeometry.Edges, steps: Int)
    /// Return: Done, not Apply.
    case done
    /// Esc: focus goes back to the photo.
    case escape

    /// The command for a key. `key` is the key's character (arrows are the
    /// `NSEvent.SpecialKey` private-use characters, Return is "\r", Esc is
    /// "\u{1b}"). nil: the overlay does not handle the key.
    ///
    /// ← → ↑ ↓ move 1 px; ⇧ makes the step 10. ⌥ + arrows resize with the
    /// bottom-right corner pulling (→ ↓ grow, ← ↑ shrink); ⌃⌥ + arrows pull
    /// with the top-left corner. ⌘ and a bare ⌃ are never ours.
    static func command(key: String, shift: Bool, option: Bool, control: Bool, command: Bool) -> CropKeyCommand? {
        guard !command else { return nil }
        if key == "\r" || key == "\u{3}" { return (shift || option || control) ? nil : .done }
        if key == "\u{1b}" { return (shift || option || control) ? nil : .escape }
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return nil }
        let steps = shift ? 10 : 1
        var dx = 0, dy = 0
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey:  dx = -1
        case NSRightArrowFunctionKey: dx = 1
        case NSUpArrowFunctionKey:    dy = -1
        case NSDownArrowFunctionKey:  dy = 1
        default: return nil
        }
        if control && !option { return nil }   // ⌃ + arrows belong to Mission Control
        if !option { return .move(dx: dx, dy: dy, steps: steps) }
        // Growing (→ ↓) is +1, shrinking (← ↑) is -1; the corner decides the edge.
        var edges = CropKeyGeometry.Edges()
        if control {
            edges.left = dx          // → grows the width, the left edge moves left
            edges.top = dy
        } else {
            edges.right = dx
            edges.bottom = dy
        }
        return .resize(edges, steps: steps)
    }
}

enum CropKeyGeometry {

    /// Per edge: +1 moves it outward (the frame grows), -1 inward, 0 stays.
    struct Edges: Equatable {
        var left = 0, top = 0, right = 0, bottom = 0
        init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) {
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
        }
    }

    struct Outcome: Equatable {
        var rect: CGRect
        /// The step was cut short (or lost) by the edge of the photo, or by
        /// the one-pixel minimum.
        var hitEdge: Bool
    }

    /// The eight handles, in the order VoiceOver reads them.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var label: String {
            switch self {
            case .topLeft: return "Top left corner"
            case .top: return "Top edge"
            case .topRight: return "Top right corner"
            case .right: return "Right edge"
            case .bottomRight: return "Bottom right corner"
            case .bottom: return "Bottom edge"
            case .bottomLeft: return "Bottom left corner"
            case .left: return "Left edge"
            }
        }

        /// The edges this handle drags; `grow` is +1 (increment) or -1 (decrement).
        func edges(grow: Int) -> Edges {
            switch self {
            case .topLeft: return Edges(left: grow, top: grow)
            case .top: return Edges(top: grow)
            case .topRight: return Edges(top: grow, right: grow)
            case .right: return Edges(right: grow)
            case .bottomRight: return Edges(right: grow, bottom: grow)
            case .bottom: return Edges(bottom: grow)
            case .bottomLeft: return Edges(left: grow, bottom: grow)
            case .left: return Edges(left: grow)
            }
        }
    }

    /// Moves the frame `steps` pixels toward (dx, dy), never out of the
    /// photo: a step that would leave it is cut to the edge.
    static func move(_ rect: CGRect, in image: CGSize, dx: Int, dy: Int, steps: Int) -> Outcome {
        let maxX = image.width - rect.width, maxY = image.height - rect.height
        var out = rect
        out.origin.x = min(max(rect.origin.x + CGFloat(dx * steps), 0), max(maxX, 0))
        out.origin.y = min(max(rect.origin.y + CGFloat(dy * steps), 0), max(maxY, 0))
        let wanted = (dx != 0 || dy != 0) && steps > 0
        return Outcome(rect: out, hitEdge: wanted && out != rect.offsetBy(dx: CGFloat(dx * steps), dy: CGFloat(dy * steps)))
    }

    /// Moves edges by up to `steps` pixels. With `aspect` (W / H) the other
    /// side follows, rounded to a whole pixel: when the width is driven
    /// (left / right edge, or a corner) the height follows on the side away
    /// from the fixed edge; when only the height is driven the width follows.
    /// The largest step that keeps the frame inside the photo (and at least
    /// 1 pixel) is used; if none fits the frame stays.
    static func resize(_ rect: CGRect, in image: CGSize, edges: Edges, steps: Int, aspect: Double?) -> Outcome {
        guard steps > 0 else { return Outcome(rect: rect, hitEdge: false) }
        var k = steps
        while k > 0 {
            if let candidate = grown(rect, edges: edges, by: k, aspect: aspect),
               fits(candidate, in: image) {
                return Outcome(rect: candidate, hitEdge: k < steps)
            }
            k -= 1
        }
        return Outcome(rect: rect, hitEdge: true)
    }

    private static func grown(_ rect: CGRect, edges e: Edges, by k: Int, aspect: Double?) -> CGRect? {
        var l = rect.minX - CGFloat(e.left * k)
        var t = rect.minY - CGFloat(e.top * k)
        var r = rect.maxX + CGFloat(e.right * k)
        var b = rect.maxY + CGFloat(e.bottom * k)
        if let ratio = aspect, ratio > 0 {
            let widthDrives = e.left != 0 || e.right != 0
            if widthDrives {
                let h = max(((r - l) / CGFloat(ratio)).rounded(), 1)
                if e.top != 0 && e.bottom == 0 { t = b - h } else { b = t + h }
            } else {
                let w = max(((b - t) * CGFloat(ratio)).rounded(), 1)
                if e.left != 0 && e.right == 0 { l = r - w } else { r = l + w }
            }
        }
        guard r - l >= 1, b - t >= 1 else { return nil }
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    private static func fits(_ rect: CGRect, in image: CGSize) -> Bool {
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= image.width && rect.maxY <= image.height
    }

    /// Applies a command to a frame.
    static func apply(_ command: CropKeyCommand, to rect: CGRect, in image: CGSize, aspect: Double?) -> Outcome? {
        switch command {
        case .move(let dx, let dy, let steps):
            return move(rect, in: image, dx: dx, dy: dy, steps: steps)
        case .resize(let edges, let steps):
            return resize(rect, in: image, edges: edges, steps: steps, aspect: aspect)
        case .done, .escape:
            return nil
        }
    }

    // MARK: Words

    /// The frame's accessibility value: `3000 by 2000 pixels, left 120, top 80`.
    static func valueText(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) by \(Int(rect.height.rounded())) pixels, left \(Int(rect.minX.rounded())), top \(Int(rect.minY.rounded()))"
    }

    static let frameLabel = "Crop frame"
    static let frameHelp = "Arrow keys move the frame. Option and arrow keys resize it. Shift makes the steps 10 pixels."
    static let edgeAnnouncement = "Edge of photo"
    /// At most one announcement per this many seconds.
    static let announcementInterval: TimeInterval = 0.25
}

/// Lets at most one announcement through per `interval`.
struct AnnouncementThrottle: Equatable {
    var interval: TimeInterval
    private var last: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func allow(at now: TimeInterval) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

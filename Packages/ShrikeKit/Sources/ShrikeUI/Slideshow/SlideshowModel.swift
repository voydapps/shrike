//
//  SlideshowModel.swift
//  ShrikeUI
//
//  Pure slideshow logic: settings and
//  their prefs, the play order (in order / random, loop), and the key
//  table. The window and timers live in `SlideshowController`.
//

import AppKit
import ShrikeCore

enum SlideshowTransition: String, CaseIterable, Sendable {
    case cut, fade, dissolve

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .dissolve: return "Dissolve"
        }
    }

    /// Cut 0 ms, Fade 320 ms (`motion.slow`), Dissolve 480 ms.
    var duration: TimeInterval {
        switch self {
        case .cut: return 0
        case .fade: return 0.32
        case .dissolve: return 0.48
        }
    }

    /// With Reduce Motion, Dissolve plays as Fade.
    func effective(reduceMotion: Bool) -> SlideshowTransition {
        reduceMotion && self == .dissolve ? .fade : self
    }
}

struct SlideshowSettings: Equatable, Sendable {
    static let intervalRange = 1...60

    var intervalSec: Int = 4
    var transition: SlideshowTransition = .fade
    var random = false
    var fill = false
    var loop = true

    static func fromPrefs() -> SlideshowSettings {
        SlideshowSettings(
            intervalSec: Prefs.slideshowIntervalSec,
            transition: SlideshowTransition(rawValue: Prefs.slideshowTransition) ?? .fade,
            random: Prefs.slideshowRandom,
            fill: Prefs.slideshowFill,
            loop: Prefs.slideshowLoop
        )
    }

    func save() {
        Prefs.slideshowIntervalSec = intervalSec
        Prefs.slideshowTransition = transition.rawValue
        Prefs.slideshowRandom = random
        Prefs.slideshowFill = fill
        Prefs.slideshowLoop = loop
    }

    /// "5 s per image".
    var intervalToast: String { "\(intervalSec) s per image" }
}

/// Play order over `count` items. `order[position]` is the item shown.
struct SlideshowPlaylist: Equatable {
    let count: Int
    private(set) var order: [Int]
    private(set) var position: Int
    var loop: Bool

    init(count: Int, start: Int, random: Bool, loop: Bool) {
        var rng = SystemRandomNumberGenerator()
        self.init(count: count, start: start, random: random, loop: loop, using: &rng)
    }

    init<R: RandomNumberGenerator>(count: Int, start: Int, random: Bool, loop: Bool, using rng: inout R) {
        self.count = max(0, count)
        self.loop = loop
        let first = min(max(0, start), max(0, count - 1))
        order = Array(0..<self.count)
        position = first
        if random { shuffle(keeping: first, using: &rng) }
    }

    var current: Int? { order.isEmpty ? nil : order[position] }
    var isAtEnd: Bool { position >= order.count - 1 }

    /// Random on: the current item stays first, the rest are shuffled.
    /// Random off: back to list order at the current item.
    mutating func setRandom(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setRandom(on, using: &rng)
    }

    mutating func setRandom<R: RandomNumberGenerator>(_ on: Bool, using rng: inout R) {
        guard let item = current else { return }
        if on {
            shuffle(keeping: item, using: &rng)
        } else {
            order = Array(0..<count)
            position = item
        }
    }

    private mutating func shuffle<R: RandomNumberGenerator>(keeping item: Int, using rng: inout R) {
        var rest = Array(0..<count).filter { $0 != item }
        rest.shuffle(using: &rng)
        order = count > 0 ? [item] + rest : []
        position = 0
    }

    /// Next item. At the end: wraps when looping, else returns false.
    @discardableResult
    mutating func next() -> Bool {
        guard !order.isEmpty else { return false }
        if position < order.count - 1 { position += 1; return true }
        guard loop else { return false }
        position = 0
        return true
    }

    @discardableResult
    mutating func previous() -> Bool {
        guard !order.isEmpty else { return false }
        if position > 0 { position -= 1; return true }
        guard loop else { return false }
        position = order.count - 1
        return true
    }

    mutating func first() { position = 0 }
    mutating func last() { position = max(0, order.count - 1) }
}

/// The slideshow's keys.
enum SlideshowKeyAction: Equatable, Sendable {
    case togglePause, next, previous, first, last
    case intervalUp, intervalDown
    case rate(Int)
    case toggleFlag, toggleRandom, toggleLoop, exit

    /// The action for a key event; the typed key goes through
    /// `KeyCharacters` (Q works on a Russian layout).
    @MainActor
    static func action(for event: NSEvent, fastStone: Bool) -> SlideshowKeyAction? {
        action(keyCode: event.keyCode, characters: KeyCharacters.key(of: event),
               modifiers: event.modifierFlags, fastStone: fastStone)
    }

    /// `fastStone`: the FastStone preset (⌫ = previous). In the Mac
    /// preset ⌫ does nothing: no trashing during a presentation.
    static func action(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, fastStone: Bool
    ) -> SlideshowKeyAction? {
        let mods = modifiers.intersection([.command, .control, .option])
        guard mods.isEmpty else { return nil }
        switch keyCode {
        case 49: return .togglePause           // Space
        case 124: return .next                 // →
        case 123: return .previous             // ←
        case 115: return .first                // Home
        case 119: return .last                 // End
        case 126: return .intervalUp           // ↑
        case 125: return .intervalDown         // ↓
        case 53: return .exit                  // Esc
        case 51: return fastStone ? .previous : nil  // ⌫
        default: break
        }
        guard let ch = characters?.lowercased(), ch.count == 1 else { return nil }
        switch ch {
        case "0", "1", "2", "3", "4", "5": return .rate(Int(ch)!)
        case "q", "\\": return .toggleFlag
        case "r": return .toggleRandom
        case "l": return .toggleLoop
        case "f": return .exit
        default: return nil
        }
    }
}

/// What the Show radio offers.
struct SlideshowScope: Equatable {
    /// All images in the window's list.
    var allCount: Int
    var folderName: String
    /// Selected images in the Browser (the second row shows only at ≥ 2).
    var selectedCount: Int

    var allTitle: String { "All \(allCount) images in “\(folderName)”" }
    var selectedTitle: String { "The \(selectedCount) selected images" }
    var offersSelection: Bool { selectedCount >= 2 }
}

//
//  ShortcutPreset.swift
//  ShrikeCore
//
//  The shortcut preset setting, and the old stored binding record.
//
//  Every key, menu key, tooltip and the Settings ▸ Shortcuts list come
//  from ONE table: `ShortcutTable` in ShrikeUI. ShrikeCore
//  keeps only what Prefs stores:
//
//    * `ShortcutPreset` — `shrike.shortcuts.preset` (Mac / FastStone).
//    * `ShortcutBinding` — the optional `shortcut` field of the old
//      3-slot external-editor records (`shrike.editors.slots`), so old
//      stored values still decode. Nothing reads it for key handling.
//
//  The old `ShortcutRegistry` actor (a second key map nobody read) was
//  removed.
//

import Foundation

// MARK: - Presets

public enum ShortcutPreset: String, Sendable, Codable, CaseIterable {
    case macNative
    case fastStoneCompat
}

// MARK: - Stored binding (legacy record field)

/// Modifier bits of a stored `ShortcutBinding`.
public struct ShrikeModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShrikeModifierFlags(rawValue: 1 << 0)
    public static let shift   = ShrikeModifierFlags(rawValue: 1 << 1)
    public static let option  = ShrikeModifierFlags(rawValue: 1 << 2)
    public static let control = ShrikeModifierFlags(rawValue: 1 << 3)
}

/// The surface a stored binding named. Only for decoding old records;
/// the live contexts are ShrikeUI's `ShortcutContext`.
public enum StoredShortcutContext: String, Sendable, Hashable {
    case global, viewer, browser, compare, edit
}

/// A key stored with an old external-editor record. Kept so old stored
/// values decode; nothing binds it.
public struct ShortcutBinding: Sendable, Hashable, Codable {
    public let key: String
    public let modifiers: ShrikeModifierFlags
    public let context: StoredShortcutContext

    public init(key: String, modifiers: ShrikeModifierFlags, context: StoredShortcutContext) {
        self.key = key
        self.modifiers = modifiers
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiers, context
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.modifiers = ShrikeModifierFlags(rawValue: try c.decode(Int.self, forKey: .modifiers))
        let raw = try c.decode(String.self, forKey: .context)
        self.context = StoredShortcutContext(rawValue: raw) ?? .global
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
        try c.encode(context.rawValue, forKey: .context)
    }
}

//
//  CellAccessibility.swift
//  ShrikeUI
//
//  The one VoiceOver label of a grid or strip cell (spec 25 §7.2): words,
//  not star glyphs. Order is fixed: name, stars, flagged, edited (spec 27 N8), pair, can't preview.
//

import Foundation

public enum CellAccessibility {

    public static func label(
        name: String, rating: Int, flagged: Bool, edited: Bool = false, isPair: Bool, failed: Bool
    ) -> String {
        var parts = [name]
        if rating > 0 { parts.append(rating == 1 ? "1 star" : "\(rating) stars") }
        if flagged { parts.append("flagged") }
        if edited { parts.append("edited") }
        if isPair { parts.append("RAW and JPEG pair") }
        if failed { parts.append("can't preview") }
        return parts.joined(separator: ", ")
    }
}

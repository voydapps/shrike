//
//  EditValueText.swift
//  ShrikeUI
//
//  One rule for the numbers next to the edit sliders. The
//  value shows the decimals of the slider's step, a sign for centred
//  sliders, and its unit: step 0.01 -> "+0.00", step 1 -> "+0", an angle
//  "12.5°" (zero shows "0°").
//

import Foundation

enum EditValueText {

    /// Number of decimals a step needs: 0.01 -> 2, 0.5 -> 1, 1 -> 0.
    static func decimals(forStep step: Double) -> Int {
        guard step > 0 else { return 0 }
        var n = 0
        var s = step
        while n < 6, abs(s - s.rounded()) > 1e-9 {
            s *= 10
            n += 1
        }
        return n
    }

    /// A signed slider at rest (or rounding to it) reads `0`; a changed one its
    /// sign and the step's decimals with a true minus (U+2212): `+0.35`, `−0.20`.
    static func text(value: Double, step: Double, signed: Bool = false, unit: String? = nil) -> String {
        let places = decimals(forStep: step)
        var v = value
        if abs(v) < 0.5 * pow(10, -Double(places)) { v = 0 }
        if v == 0 { return unit.map { "0" + $0 } ?? (signed ? "0" : String(format: "%.\(places)f", 0.0)) }
        let body = String(format: "%.\(places)f", abs(v))
        let sign = v < 0 ? (signed ? "\u{2212}" : "-") : (signed ? "+" : "")
        return sign + body + (unit ?? "")
    }

    /// VoiceOver: `0`, `plus 0.35`, `minus 0.20`.
    static func spoken(value: Double, step: Double, unit: String? = nil) -> String {
        let shown = text(value: value, step: step, signed: true, unit: unit)
        if shown.hasPrefix("+") { return "plus " + shown.dropFirst() }
        if shown.hasPrefix("\u{2212}") { return "minus " + shown.dropFirst() }
        return shown
    }
}

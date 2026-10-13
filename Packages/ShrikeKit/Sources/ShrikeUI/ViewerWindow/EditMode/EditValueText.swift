//
//  EditValueText.swift
//  ShrikeUI
//
//  Spec 27 P3-8(d): one rule for the numbers next to the edit sliders. The
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

    static func text(value: Double, step: Double, signed: Bool = false, unit: String? = nil) -> String {
        let places = decimals(forStep: step)
        var v = value
        if abs(v) < 0.5 * pow(10, -Double(places)) { v = 0 }
        if let unit, v == 0 { return "0" + unit }
        let body = String(format: "%.\(places)f", abs(v))
        let sign = v < 0 ? "-" : (signed ? "+" : "")
        return sign + body + (unit ?? "")
    }
}

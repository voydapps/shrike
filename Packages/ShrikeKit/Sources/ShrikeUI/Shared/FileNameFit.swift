//
//  FileNameFit.swift
//  ShrikeUI
//
//  Cuts a long file name so its identity survives (spec 25 §6.1). The
//  tail with the frame number and the extension is kept; the head is cut
//  and replaced by "…". A pure function: the caller measures with its own
//  font and width.
//

import Foundation

public enum FileNameFit {

    private static let ellipsis = "…"

    /// A file name for a sentence (toast, message): at most `limit` characters, the
    /// ending (number, extension) kept. A toast shows 2 lines; 255-character names
    /// would push the rest of the sentence out.
    public static func short(_ name: String, limit: Int = 40) -> String {
        fit(name) { $0.count <= limit }
    }

    /// `name` if it fits, else a shortened form. Never returns an empty string.
    public static func fit(_ name: String, fits: (String) -> Bool) -> String {
        if name.isEmpty || fits(name) { return name }
        let chars = Array(name)

        var tailStart = chars.count > 8 ? chars.count - 8 : 0
        if let run = lastDigitRunStart(chars), run > 0 {
            let candidate = String(chars[run...])
            if fits(ellipsis + candidate) { tailStart = run }
        }
        let tail = String(chars[tailStart...])
        let marked = ellipsis + tail
        if fits(marked) {
            var count = tailStart
            while count > 1 {
                let candidate = String(chars[..<count]) + marked
                if fits(candidate) { return candidate }
                count -= 1
            }
            return marked
        }
        // Step 5: not even "…" + tail fits: longest prefix of the name plus "…".
        var count = chars.count - 1
        while count > 0 {
            let candidate = String(chars[..<count]) + ellipsis
            if fits(candidate) { return candidate }
            count -= 1
        }
        return ellipsis
    }

    /// Index of the first character of the last run of 3 or more digits in the stem.
    private static func lastDigitRunStart(_ chars: [Character]) -> Int? {
        let stemEnd = chars.lastIndex(of: ".").flatMap { $0 > 0 ? $0 : nil } ?? chars.count
        var best: Int?
        var i = 0
        while i < stemEnd {
            if chars[i].isASCII, chars[i].isNumber {
                var j = i
                while j < stemEnd, chars[j].isASCII, chars[j].isNumber { j += 1 }
                if j - i >= 3 { best = i }
                i = j
            } else {
                i += 1
            }
        }
        return best
    }
}

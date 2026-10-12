//
//  FileSizeText.swift
//  ShrikeUI
//
//  One formatter for file sizes (spec 25 §2.3): under 1 KB the number of
//  bytes shows ("100 bytes"), not "0 KB".
//

import Foundation

public enum FileSizeText {

    /// `style` is `.file` everywhere except the Settings cache sizes, which
    /// are powers of two and read best as `.binary` ("512 MB").
    public static func string(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        // A fresh formatter per call: ByteCountFormatter is not Sendable and
        // this is not a hot path (inspector, list cells).
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

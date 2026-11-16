//
//  DebugReviewOptions.swift
//  ShrikeUI
//
//  Debug builds only: launch options that slow a step down so an
//  on-screen reviewer can see a state that is normally too short:
//
//    -ShrikeDebugPrintLoadDelay <seconds>  each photo's load for printing
//                                          (the "Getting photos ready" sheet)
//    -ShrikeDebugTransferDelay <seconds>   each photo of a copy / move
//                                          ("quit during a copy")
//  Read once, the first time a print or a transfer starts (never at
//  launch). Not compiled into Release.
//

#if DEBUG
import Foundation
import ShrikeIO

enum DebugReviewOptions {
    struct Values: Equatable, Sendable {
        var printLoadDelay: Double = 0
        var transferDelay: Double = 0
    }

    /// The longest delay accepted (seconds).
    static let maxDelay: Double = 30

    /// Pure: the values in `arguments` (missing, not a number or negative → 0).
    static func parse(_ arguments: [String]) -> Values {
        func value(_ name: String) -> Double {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count,
                  let seconds = Double(arguments[i + 1]), seconds.isFinite, seconds > 0 else { return 0 }
            return min(seconds, maxDelay)
        }
        return Values(printLoadDelay: value("-ShrikeDebugPrintLoadDelay"),
                      transferDelay: value("-ShrikeDebugTransferDelay"))
    }

    /// This process's options; reading it also hands the transfer delay to `FileOps`.
    static let current: Values = {
        let values = parse(ProcessInfo.processInfo.arguments)
        FileOps.debugPerFileDelay.withLock { $0 = values.transferDelay }
        return values
    }()
}
#endif

//
//  TestPerf.swift
//  Copied into every test target (the targets share no code), like TestDefaults.swift.
//
//  Wall-clock checks do not belong in a normal run: on a busy machine (CI, other
//  builds) they fail by chance. `perfAssertLessThan` always prints the measured
//  value, and asserts the budget only when SHRIKE_BENCH is set (the same switch
//  the benchmark classes use).
//

import Foundation
import XCTest

/// True when the opt-in performance run is on (`SHRIKE_BENCH=1 swift test ...`).
let perfAssertionsEnabled = ProcessInfo.processInfo.environment["SHRIKE_BENCH"] != nil

func perfAssertLessThan<T: Comparable>(
    _ value: @autoclosure () throws -> T,
    _ budget: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) rethrows {
    let v = try value(), b = try budget()
    print("[perf] \((file.description as NSString).lastPathComponent):\(line) measured \(v), budget \(b)"
          + (perfAssertionsEnabled ? "" : " (not asserted; set SHRIKE_BENCH=1)"))
    guard perfAssertionsEnabled else { return }
    XCTAssertLessThan(v, b, message(), file: file, line: line)
}

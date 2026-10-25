//
//  LifetimeDiagnostics.swift
//  ShrikeUITests
//
//  Failure-only help for the window-lifetime tests: when a closed window is
//  still alive at the end of the wait, print who holds it (`leaks --trace`),
//  every thread's stack (`sample`) and the Swift tasks (`swift-inspect`).
//  A hosted runner once kept closed viewers alive for a whole run and the
//  cause could not be reproduced; the next time, the log names the holder.
//  Runs only when the test is about to fail, so passing runs are unchanged.
//

import AppKit
import Metal
import XCTest
@testable import ShrikeRendering

@MainActor
enum LifetimeDiagnostics {

    static func dump(_ label: String, alive: [(String, AnyObject)]) {
        var out = "===== LIFETIME DIAGNOSTICS \(label)\n"
        for screen in NSScreen.screens {
            out += "screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)\n"
        }
        out += "metal=\(MTLCreateSystemDefaultDevice()?.name ?? "nil") reduceMotion=\(ReduceMotion.isOn)\n"
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        for (name, object) in alive.prefix(2) {
            let address = "0x" + String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()), radix: 16)
            out += "----- leaks --trace \(name) \(address)\n" + run("/usr/bin/leaks", ["--trace=\(address)", pid])
        }
        let sampled = run("/usr/bin/sample", [pid, "1"])
        out += "----- sample\n" + (sampled.components(separatedBy: "Binary Images:").first ?? sampled)
        out += "----- swift-inspect dump-concurrency\n" + run("/usr/bin/swift-inspect", ["dump-concurrency", pid])
        print(out + "===== END LIFETIME DIAGNOSTICS")
    }

    /// Runs a tool (at most 150 s); its output goes through a temp file
    /// so a large output cannot fill a pipe while this thread waits.
    private static func run(_ tool: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return "(\(tool) not available)\n" }
        let file = TestScratch.directory.appendingPathComponent("shrike-diag-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return "(no output file)\n" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return "(could not run \(tool): \(error))\n" }
        let deadline = Date().addingTimeInterval(150)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? handle.close()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "(unreadable)"
        return String(text.prefix(200_000)) + "\n"
    }
}

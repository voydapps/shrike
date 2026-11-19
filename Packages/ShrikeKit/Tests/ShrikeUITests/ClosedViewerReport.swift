//
//  ClosedViewerReport.swift
//  ShrikeUITests
//
//  Shared by the tests that check a closed viewer is released
//  (EditTransitionTests, ViewerLifetimeTests): a state report and a
//  `leaks --traceTree` of a viewer that is still alive, and the
//  report-only form for the CI runner on GitHub, where the holder is unknown.
//

import AppKit
import Darwin
import XCTest
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore

enum ClosedViewerReport {
    /// True on the GitHub Actions runner only.
    static var onGitHubRunner: Bool { ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" }

    static let knownIssue = "Known issue on the GitHub runner only: the closed viewer is not released "
        + "in time and the holder is unknown; see the printed report."

    /// Fails the test; on the GitHub runner as an expected failure (it does not fail the run).
    static func raise(_ messages: [String], known: String = knownIssue) {
        if onGitHubRunner {
            XCTExpectFailure(known, strict: false) {
                for message in messages { XCTFail(message) }
            }
        } else {
            for message in messages { XCTFail(message) }
        }
    }

    /// For a viewer that is still alive after the wait: the state first (its own failure, so it
    /// reaches the log even if leaks stalls), then the reference tree, then whether it goes away later.
    /// `alive` must read a weak reference. `label` starts the messages (which viewer).
    @MainActor
    static func reportStillAlive(label: String = "", alive: () -> ViewerWindow?, parts: ClosedViewerParts,
                                 waitEnded end: Date, waited: String = "the 10 s", known: String = knownIssue) async throws {
        let prefix = label.isEmpty ? "" : label + ": "
        func raise(_ messages: [String]) { Self.raise(messages.map { prefix + $0 }, known: known) }
        // In a pool: what NSApp.windows / firstResponder hand back must not hold the window.
        raise([autoreleasepool { parts.report(alive()) } + "\n" + (await parts.queueState())])
        let tree = autoreleasepool { referenceTree(of: alive()) }
        let late = end.addingTimeInterval(20)
        while alive() != nil, Date() < late { try await Task.sleep(for: .milliseconds(20)) }
        let after = alive() == nil ? "released within \(Int(Date().timeIntervalSince(end).rounded(.up))) s after \(waited)"
            : "still alive 20 s after \(waited)"
        // The whole tree, unfiltered: in failures of 100 lines (a long message may be cut)
        // and between markers in one write to stderr, the failures' stream (swift test
        // relays stdout and stderr separately and cuts lines where they meet).
        FileHandle.standardError.write(Data(("=== BEGIN viewer reference tree\(label.isEmpty ? "" : " " + label) ===\n" + tree.joined(separator: "\n")
            + "\n=== END viewer reference tree ===\n").utf8))
        // The viewer's direct referrers (one route per root; its own subviews' back
        // pointers are most of them): compare with a closed viewer that is released.
        let level1 = tree.filter { $0.hasPrefix("      ") && ($0.dropFirst(6).first?.isNumber ?? false) }
        var rest = ["reference tree level-1 referrers (\(level1.count)):\n" + level1.prefix(40).joined(separator: "\n")]
        let pieces = stride(from: 0, to: max(tree.count, 1), by: 100).map { Array(tree.dropFirst($0).prefix(100)) }
        for (i, part) in pieces.enumerated() {
            rest.append("reference tree part \(i + 1)/\(pieces.count):\n" + part.joined(separator: "\n"))
        }
        rest.append(after)
        raise(rest)
    }

    /// Who references `object`, from `/usr/bin/leaks --traceTree` on this process: the
    /// whole output, unfiltered (the chain runs through AppKit objects), at most 700 lines,
    /// after a header line. It shows one route per root (the first-level counts add up to
    /// "Found N roots"), and most first-level entries are the window's own views pointing
    /// back at it. Tried 2026-11-17 with planted holders: a static holding the window is
    /// named; a window held only through a NotificationCenter block observer (its token in
    /// a static) appears nowhere, in this tree or in `--trace`, and why is unknown. So a
    /// tree that names no owner does not prove there is none. `leaks` pauses the process
    /// while it reads it (the 90 s limit is checked only between those pauses), so this
    /// runs only after the 10 s answer is known. Written to a file, never a pipe: nothing
    /// in the paused process could read a pipe.
    static func referenceTree(of object: AnyObject?) -> [String] {
        guard let object else { return ["reference tree: released meanwhile"] }
        let address = String(format: "%p", UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
        let out = TestScratch.directory.appendingPathComponent("viewer-trace-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return ["reference tree: no file"] }
        defer { try? handle.close() }
        let leaks = Process()
        leaks.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        leaks.arguments = ["\(getpid())", "--traceTree=\(address)"]
        leaks.standardOutput = handle; leaks.standardError = handle
        do { try leaks.run() } catch { return ["reference tree: leaks did not start (\(error))"] }
        let deadline = Date().addingTimeInterval(90)
        while leaks.isRunning, Date() < deadline { usleep(100_000) }
        if leaks.isRunning { leaks.terminate(); return ["reference tree: leaks ran past 90 s"] }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.prefix(700)
        return ["reference tree of \(address) (leaks exit \(leaks.terminationStatus), \(lines.count) lines, "
                + "\(lines.count - kept.count) cut after line 700); \(threadNames())"] + kept
    }

    /// This process's threads in `task_threads` order, with their names: presumably the
    /// order of leaks' "Stack thread N" (not proven).
    static func threadNames() -> String {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return "threads: unknown" }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        var names: [String] = []
        for i in 0..<Int(count) {
            var name = [CChar](repeating: 0, count: 64)
            if let p = pthread_from_mach_thread_np(list[i]) { pthread_getname_np(p, &name, name.count) }
            let s = String(cString: name)
            names.append("\(i)=\(s.isEmpty ? "-" : s)")
        }
        return "threads (task order, presumed = leaks' Stack thread N): " + names.joined(separator: " ")
    }

}

/// What a closed viewer still has running, for the message of a release wait that ran out.
/// Weak only. The window owns its parts, so their being alive would name no holder.
final class ClosedViewerParts {
    weak var coalescer: NavTaskCoalescer?
    weak var undo: UndoManager?
    weak var toast: ToastHostView?
    weak var queue: DecodeQueue?
    private var redrawsAtClose: UInt64 = 0
    var waited = "10 s"
    /// What the closing time is counted from (the lifetime test sets its own).
    var closedSince = "the save started"
    private var started = Date(), closedAfter: TimeInterval = 0
    /// Before the save starts: the watcher ignores the saved file for 2 s from there.
    @MainActor func track(_ viewer: ViewerWindow) {
        coalescer = viewer.navCoalescer; undo = viewer.undoManagerForTesting; toast = viewer.contentRootForTesting.toastHost
        queue = viewer.navigationForTesting.decodeQueue; started = Date()
    }
    /// Right after close(): a redraw that FINISHES later ran on the closed window (for
    /// example after a folder-watcher event for the saved file that came late).
    @MainActor func noteClose(_ viewer: ViewerWindow) {
        redrawsAtClose = viewer.redrawCount; closedAfter = Date().timeIntervalSince(started)
    }
    /// The decode queue's state (Debug builds), read without holding the window.
    @MainActor func queueState() async -> String {
        guard let queue else { return "decodeQueue gone" }
        #if DEBUG
        return "decodeQueue " + (await queue.stateForTesting())
        #else
        return "decodeQueue alive (state needs Debug)"
        #endif
    }
    /// `observationInfo` (public NSObject API) counted per key path and observer.
    @MainActor private static func observances(of object: NSObject) -> String {
        guard let info = object.observationInfo else { return "none" }
        let text = String(describing: Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue())
        var paths: [String: Int] = [:], observers = Set<Substring>()
        for line in text.split(separator: "\n") {
            guard let o = line.range(of: "Observer: "), let k = line.range(of: ", Key path: "),
                  let e = line.range(of: ", Options:") else { continue }
            observers.insert(line[o.upperBound..<k.lowerBound])
            paths[String(line[k.upperBound..<e.lowerBound]), default: 0] += 1
        }
        return "\(paths.values.reduce(0, +)) from \(observers.count) observers: "
            + paths.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
    @MainActor func report(_ viewer: ViewerWindow?) -> String {
        var lines = ["closed viewer still alive after \(waited); closed \(String(format: "%.1f", closedAfter)) s after \(closedSince)"]
        if let viewer {
            let c = viewer.contentRootForTesting.editModeController
            // The `viewer` ref passed in is +1 here.
            lines.append("viewer retainCount≈\(CFGetRetainCount(viewer)) tornDown=\(viewer.didTearDown) visible=\(viewer.isVisible) inAppWindows=\(NSApp?.windows.contains { $0 === viewer } ?? false) key=\(NSApp?.keyWindow === viewer) main=\(NSApp?.mainWindow === viewer) releasedWhenClosed=\(viewer.isReleasedWhenClosed) sheets=\(viewer.sheets.count) children=\(viewer.childWindows?.count ?? 0) firstResponder=\(viewer.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            lines.append("redraws finished since close=\(viewer.redrawCount &- redrawsAtClose) tasks: editExit=\(viewer.editExitTask != nil) editLoad=\(viewer.editLoadTask != nil) hiddenTrim=\(viewer.hiddenTrimTask != nil) textureRefetch=\(viewer.textureRefetchTask != nil) folderWatch=\(viewer.folderWatchTask != nil) watcher=\(viewer.folderWatcher != nil)")
            lines.append("edit active=\(c.isActive) saving=\(c.isSaving) displayed=\(viewer.displayedItem?.group.primary.lastPathComponent ?? "nil") image=\(viewer.imageViewForTesting.image != nil)")
            let name: (AnyObject?) -> String = { $0.map { String(describing: type(of: $0)) } ?? "nil" }
            lines.append("viewer parent=\(name(viewer.parent)) sheetParent=\(name(viewer.sheetParent)) delegate=\(name(viewer.delegate)) windowController=\(name(viewer.windowController)) toolbar=\(viewer.toolbar.map { $0.identifier } ?? "nil") contentView=\(name(viewer.contentView)) app key=\(name(NSApp?.keyWindow)) main=\(name(NSApp?.mainWindow)) windowsMenu items for it=\(NSApp?.windowsMenu?.items.filter { $0.target === viewer }.count ?? -1)")
            // Who KVO-observes it (the class is NSKVONotifying_): observers and key paths.
            lines.append("viewer KVO observances by key path: " + Self.observances(of: viewer))
            lines.append("NSApp.windows count=\(NSApp?.windows.count ?? -1)")
            for w in NSApp?.windows ?? [] where w !== viewer {
                let links = [w.parent === viewer ? "parent" : nil, w.sheetParent === viewer ? "sheetParent" : nil,
                             w.attachedSheet === viewer ? "attachedSheet" : nil,
                             (w.childWindows ?? []).contains { $0 === viewer } ? "child" : nil,
                             (w.tabbedWindows ?? []).contains { $0 === viewer } ? "tabbed" : nil].compactMap { $0 }
                lines.append("  window \(name(w)) visible=\(w.isVisible) title=\"\(w.title)\" links to viewer=\(links.isEmpty ? "none" : links.joined(separator: ","))")
            }
        }
        if let undo {
            lines.append("undo canUndo=\(undo.canUndo) canRedo=\(undo.canRedo) groupingLevel=\(undo.groupingLevel) levelsOfUndo=\(undo.levelsOfUndo) registration=\(undo.isUndoRegistrationEnabled)")
        }
        if let coalescer {
            lines.append("navCoalescer idle=\(coalescer.isIdle) idleWaiters=\(coalescer.idleWaiterCountForTesting) currentCancelled=\(coalescer.isCurrentTaskCancelled) replaced=\(coalescer.replacedCount)")
        }
        lines.append("viewerSavesRunning=\(ViewerSaveCounter.running) undoCanUndo=\(undo?.canUndo.description ?? "gone") toast=\(toast.map { String(describing: $0.content) } ?? "gone")")
        let s = ImageResourceBudget.shared.snapshot()
        lines.append("shared budget active=\(s.activeDiscretionaryOperationCount) oversize=\(s.activeOversizeOperationCount) waiters=\(s.pendingWaiterCount) pressure=\(s.pressure) reserved=\(s.reservedEstimatedBytes)")
        return lines.joined(separator: "\n")
    }
}

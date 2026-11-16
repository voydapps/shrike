//
//  FrameAutosave.swift
//  ShrikeCore
//
//  AppKit saves a window's frame under "NSWindow Frame <name>" in
//  `UserDefaults.standard`, with no way to give it another store. Under tests
//  that is the test runner's own domain, shared by every parallel worker, so
//  two workers overwrite each other's saved frame (BrowserNewWindowFrameTests
//  failed under `swift test --parallel`). In Debug test runs the name gets a
//  per-process suffix and the keys are removed when the process exits.
//  The shipped app (Release, or not running tests) uses the plain name.
//

import Foundation

public enum FrameAutosave {
    public static func name(_ base: String) -> String {
        #if DEBUG
        guard ShrikeDataPaths.isRunningTests else { return base }
        let name = "\(base).tests-\(getpid())"
        Registry.add(name)
        return name
        #else
        return base
        #endif
    }

    #if DEBUG
    private enum Registry {
        nonisolated(unsafe) private static var names = Set<String>()
        private static let lock = NSLock()
        private static let installExit: Void = {
            sweepDeadProcesses()
            atexit { Registry.removeAll() }
        }()

        /// `atexit` does not run when a test process crashes or is killed, so
        /// keys of dead processes ("... .tests-<pid>") are removed here, the next
        /// time any test process starts.
        private static func sweepDeadProcesses() {
            let prefix = "NSWindow Frame "
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                guard let range = key.range(of: ".tests-", options: .backwards),
                      let pid = pid_t(key[range.upperBound...]) else { continue }
                if pid != getpid(), kill(pid, 0) != 0, errno == ESRCH {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        static func add(_ name: String) {
            _ = installExit
            lock.lock(); names.insert(name); lock.unlock()
        }
        static func removeAll() {
            lock.lock(); let all = names; lock.unlock()
            for name in all { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
            UserDefaults.standard.synchronize()
        }
    }
    #endif
}

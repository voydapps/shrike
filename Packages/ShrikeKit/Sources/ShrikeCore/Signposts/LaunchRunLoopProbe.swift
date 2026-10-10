//
//  LaunchRunLoopProbe.swift
//  ShrikeCore
//
//  Shows what the main run loop does during
//  launch, as signposts next to the launch ones:
//
//  - `rlIdle`: the main thread sleeps (waits for an event, a timer or a
//    task). Time inside it is not main-thread work.
//  - `rlCommit`: AppKit's layout and display pass plus the Core
//    Animation commit at the end of a run-loop turn.
//
//  Everything else between two launch signposts is main-thread work of
//  that turn. Installed from `main.swift`; removes itself after
//  `duration`, so a running app has no observers. Signposts cost almost
//  nothing when nothing records them.
//

import CoreFoundation
import Foundation
import os

public enum LaunchRunLoopProbe {

    /// Default: long enough to cover a cold open with a photo.
    public static let defaultDuration: TimeInterval = 3

    @MainActor private static var observers: [CFRunLoopObserver] = []
    @MainActor private static var idleState: OSSignpostIntervalState?
    @MainActor private static var commitState: OSSignpostIntervalState?

    /// Adds the observers to the main run loop (common modes).
    @MainActor
    public static func install(duration: TimeInterval = defaultDuration) {
        guard observers.isEmpty else { return }
        let loop = CFRunLoopGetMain()
        // Before AppKit's display cycle (order ~1,999,000) and the Core
        // Animation commit (2,000,000).
        let commitBegin = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, _ in
            MainActor.assumeIsolated {
                if commitState == nil {
                    commitState = ShrikeSignposts.launch.begin("rlCommit")
                }
            }
        }
        // After both: the thread is about to sleep.
        let sleepBegin = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated {
                if let box = commitState {
                    ShrikeSignposts.launch.end("rlCommit", box)
                    commitState = nil
                }
                if idleState == nil {
                    idleState = ShrikeSignposts.launch.begin("rlIdle")
                }
            }
        }
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in
            MainActor.assumeIsolated {
                if let box = idleState {
                    ShrikeSignposts.launch.end("rlIdle", box)
                    idleState = nil
                }
            }
        }
        for observer in [commitBegin, sleepBegin, wake].compactMap({ $0 }) {
            CFRunLoopAddObserver(loop, observer, .commonModes)
            observers.append(observer)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { remove() }
        }
    }

    @MainActor
    static func remove() {
        let loop = CFRunLoopGetMain()
        for observer in observers {
            CFRunLoopRemoveObserver(loop, observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        if let box = idleState { ShrikeSignposts.launch.end("rlIdle", box) }
        if let box = commitState { ShrikeSignposts.launch.end("rlCommit", box) }
        idleState = nil
        commitState = nil
    }
}

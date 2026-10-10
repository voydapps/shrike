//
//  main.swift
//  Shrike
//
//  Manual entry point — we deliberately avoid SwiftUI's `@main App`.
//  Reasoning: the app shell must be
//  NSApplicationDelegate + NSDocumentController so we control launch
//  services, file-open events, drag-to-dock, and first-frame paint timing.
//

import AppKit
import ShrikeCore
import ShrikeUI

// Fire the launch signpost as early as possible — before NSApp even exists.
// This is the t=0 anchor for the <250 ms cold-launch target.
let launchSignpost = ShrikeSignposts.launch.begin("coldLaunch", "main.swift")

// Idle / commit intervals of the main run loop during
// launch (removes itself after 3 s).
LaunchRunLoopProbe.install()

// Shader compile + Metal device off the main thread, in parallel with
// AppKit's own launch work. Starting it after `NSApplication.shared`
// was tried (a `sample` showed the two
// threads waiting on the same loader lock): `sharedApplication` did not
// get shorter (63 vs 61 ms) and `appKitGap` grew (84 vs 74 ms), so it
// stays here.
ViewerWarmUp.start()

// Each main-thread step before AppKit's run
// loop gets its own signpost, so the time between `main` and
// `willFinishLaunching` can be split.
// Ensure our custom NSDocumentController is instantiated before NSApp looks
// for one (AppKit uses whichever instance exists first).
let docState = ShrikeSignposts.launch.begin("documentController")
_ = ShrikeDocumentController.shared
ShrikeSignposts.launch.end("documentController", docState)

let appState = ShrikeSignposts.launch.begin("sharedApplication")
let app = NSApplication.shared
ShrikeSignposts.launch.end("sharedApplication", appState)

let delegateState = ShrikeSignposts.launch.begin("appDelegateInit")
let delegate = AppDelegate(launchSignpost: launchSignpost)
app.delegate = delegate
ShrikeSignposts.launch.end("appDelegateInit", delegateState)
// Until `applicationWillFinishLaunching`: AppKit's own start-up.
AppDelegate.appKitStartState = ShrikeSignposts.launch.begin("appKitStart")
app.run()

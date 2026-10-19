import AppKit
import QuartzCore
import os

/// Active-only comparison clock. The shipping choice stays legacy until
/// available-display pacing/CPU measurements justify changing it.
@MainActor
public final class ActiveAnimationClock: NSObject {
    public enum Mode: Sendable { case legacy120, displayRefresh }
    public static var mode: Mode = ProcessInfo.processInfo.environment["SHRIKE_ANIMATION_CLOCK"] == "display" ? .displayRefresh : .legacy120
    public private(set) static var recentFrameIntervals: [CFTimeInterval] = []
    private var timer: Timer?
    private var link: CADisplayLink?
    private var proxy: Proxy?
    private var lastTime: CFTimeInterval?
    private var intervals: [CFTimeInterval] = []
    private var stopped = false
    private let started = CACurrentMediaTime()
    private let capturedMode = ActiveAnimationClock.mode
    private static let profileLog = Logger(subsystem: "app.shrike", category: "animationClock")
    private var callback: ((CFTimeInterval) -> Bool)?
    public init(view: NSView, callback: @escaping @MainActor (CFTimeInterval) -> Bool) {
        self.callback = callback
        super.init()
        if Self.mode == .displayRefresh {
            let proxy = Proxy(); proxy.owner = self; self.proxy = proxy
            let link = view.displayLink(target: proxy, selector: #selector(Proxy.tick))
            self.link = link; proxy.link = link
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                guard self != nil else { timer.invalidate(); return }
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func tick() {
        let now = CACurrentMediaTime()
        if let lastTime {
            intervals.append(now - lastTime)
            Self.recentFrameIntervals.append(now - lastTime)
            if Self.recentFrameIntervals.count > 1024 { Self.recentFrameIntervals.removeFirst(512) }
        }
        lastTime = now
        if callback?(now) != true { invalidate() }
    }
    public func invalidate() {
        guard !stopped else { return }; stopped = true
        if ProcessInfo.processInfo.environment["SHRIKE_ANIMATION_PROFILE"] == "1" {
            let sorted = intervals.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
            let mode = capturedMode == .displayRefresh ? "display" : "legacy120"
            Self.profileLog.info("animationClock mode=\(mode, privacy: .public) frames=\(self.intervals.count + 1) medianMs=\(median) p95Ms=\(p95) activeMs=\((CACurrentMediaTime() - self.started) * 1000)")
        }
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil
        proxy = nil; callback = nil
    }
    @MainActor private final class Proxy: NSObject {
        weak var owner: ActiveAnimationClock?
        weak var link: CADisplayLink?
        @objc func tick() { if let owner { owner.tick() } else { link?.invalidate() } }
    }
}

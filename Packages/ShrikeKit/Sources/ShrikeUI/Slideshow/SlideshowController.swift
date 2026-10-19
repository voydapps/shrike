//
//  SlideshowController.swift
//  ShrikeUI
//
//  The slideshow window: a borderless
//  window on the origin's screen, Dock and menu bar hidden while it is
//  key, two Metal views for Cut / Fade / Dissolve, the next two images
//  decoded ahead, the keys, the control bar and the
//  pause indicator. Everything is released on exit.
//

import AppKit
import ShrikeCore
import ShrikeRendering

/// Whoever started the slideshow (a viewer or a Browser).
@MainActor
protocol SlideshowOrigin: AnyObject {
    var slideshowUndoManager: UndoManager? { get }
    /// A rating or flag changed during the show.
    func slideshowDidChangeCulling(_ values: [URL: FileRecord])
    /// The show ended; move to `lastShown`. `finished`: it ran out
    /// (loop off) — the origin shows "Slideshow finished."
    func slideshowDidEnd(lastShown: ImageGroup?, finished: Bool)
}

@MainActor
final class SlideshowController: NSObject, NSWindowDelegate {

    /// The show on screen (one at a time); keeps the controller alive.
    private(set) static var active: SlideshowController?

    let groups: [ImageGroup]
    private(set) var settings: SlideshowSettings
    private(set) var playlist: SlideshowPlaylist
    private(set) var isPaused = false
    /// Groups shown so far, in order (tests: no black frame, last shown).
    private(set) var shownHistory: [Int] = []
    /// Item currently fully on screen.
    private(set) var shownIndex: Int?

    private let services: ShrikeServices
    private weak var origin: (any SlideshowOrigin)?
    private let presentsOnScreen: Bool
    private let queue: DecodeQueue
    private var window: SlideshowWindow?
    private var front: MetalImageView?
    private var back: MetalImageView?
    private let controlBar = SlideshowControlBar()
    private let pauseIndicator = SlideshowPauseIndicator()
    private let toastHost = ToastHostView(placement: .viewer)
    private var advanceTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    /// The decode list follows the play order; shows wait for it.
    private var listTask: Task<Void, Never>?
    private var showGeneration = 0
    private var activity: (any NSObjectProtocol)?
    private var savedPresentation: NSApplication.PresentationOptions = []
    private var pointerTimer: Timer?
    private var barTimer: Timer?
    private var ended = false
    /// Tests: seconds per image override (the prefs floor is 1 s).
    var intervalOverrideForTesting: TimeInterval?
    /// Tests: toasts shown.
    private(set) var toastsForTesting: [String] = []

    init(groups: [ImageGroup], start: Int, settings: SlideshowSettings,
         services: ShrikeServices, origin: (any SlideshowOrigin)?, presentsOnScreen: Bool = true) {
        self.groups = groups
        self.settings = settings
        self.services = services
        self.origin = origin
        self.presentsOnScreen = presentsOnScreen
        self.playlist = SlideshowPlaylist(count: groups.count, start: start,
                                          random: settings.random, loop: settings.loop)
        self.queue = services.makeDisplayDecodeQueue()
        super.init()
    }

    // MARK: Start / exit

    /// Opens the window on `screen` and shows the first image.
    func start(on screen: NSScreen?) {
        Self.active?.exit(finished: false)
        Self.active = self
        if presentsOnScreen, let screen = screen ?? NSScreen.main {
            buildWindow(frame: screen.frame)
        }
        updateActivity()
        listTask = Task { await self.resetQueueList() }
        show(position: playlist.position, animated: false)
    }

    /// Restores the Dock and menu bar, closes the window, releases the
    /// textures and moves the origin to the last image shown.
    func exit(finished: Bool) {
        guard !ended else { return }
        ended = true
        advanceTask?.cancel()
        showTask?.cancel()
        pointerTimer?.invalidate()
        barTimer?.invalidate()
        endActivity()
        if let window {
            window.delegate = nil
            if NSApp.presentationOptions != savedPresentation, window.isKeyWindow {
                NSApp.presentationOptions = savedPresentation
            }
            NSCursor.unhide()
            window.orderOut(nil)
            window.close()
        }
        front?.releaseResources()
        back?.releaseResources()
        front = nil
        back = nil
        window = nil
        let queue = self.queue
        Task { await queue.purge() }
        let last = shownIndex.map { groups[$0] }
        if Self.active === self { Self.active = nil }
        origin?.slideshowDidEnd(lastShown: last, finished: finished)
    }

    // MARK: Keys and controls

    func handle(_ action: SlideshowKeyAction) {
        guard !ended else { return }
        switch action {
        case .togglePause:
            setPaused(!isPaused)
        case .next:
            if playlist.next() { show(position: playlist.position, animated: true) }
        case .previous:
            if playlist.previous() { show(position: playlist.position, animated: true) }
        case .first:
            playlist.first()
            show(position: playlist.position, animated: true)
        case .last:
            playlist.last()
            show(position: playlist.position, animated: true)
        case .intervalUp, .intervalDown:
            let delta = action == .intervalUp ? 1 : -1
            settings.intervalSec = min(SlideshowSettings.intervalRange.upperBound,
                                       max(SlideshowSettings.intervalRange.lowerBound,
                                           settings.intervalSec + delta))
            settings.save()
            controlBar.sync(settings: settings, paused: isPaused)
            toast(settings.intervalToast)
            if !isPaused, shownIndex != nil { scheduleAdvance() }
        case .rate(let stars):
            rateShown(stars)
        case .toggleFlag:
            toggleFlagShown()
        case .toggleRandom:
            setRandom(!settings.random)
        case .toggleLoop:
            setLoop(!settings.loop)
        case .exit:
            exit(finished: false)
        }
    }

    func setRandom(_ on: Bool) {
        settings.random = on
        settings.save()
        playlist.setRandom(on)
        let previous = listTask
        listTask = Task { await previous?.value; await self.resetQueueList() }
        controlBar.sync(settings: settings, paused: isPaused)
        toast(on ? "Random order on" : "Random order off")
    }

    func setLoop(_ on: Bool) {
        settings.loop = on
        playlist.loop = on
        settings.save()
        controlBar.sync(settings: settings, paused: isPaused)
        toast(on ? "Loop on" : "Loop off")
    }

    func setTransition(_ transition: SlideshowTransition) {
        settings.transition = transition
        settings.save()
        controlBar.sync(settings: settings, paused: isPaused)
    }

    func setInterval(_ seconds: Int) {
        settings.intervalSec = min(60, max(1, seconds))
        settings.save()
        controlBar.sync(settings: settings, paused: isPaused)
        if !isPaused, shownIndex != nil { scheduleAdvance() }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        pauseIndicator.isHidden = !paused
        controlBar.sync(settings: settings, paused: paused)
        updateActivity()
        if paused { advanceTask?.cancel() } else if shownIndex != nil { scheduleAdvance() }
    }

    private func rateShown(_ stars: Int) {
        guard let index = shownIndex else { return }
        let urls = Culling.imageURLs(of: groups[index])
        CullingUndo.perform(
            .rating, urls: urls, store: services.metadataStore,
            undoManager: origin?.slideshowUndoManager,
            compute: { Culling.ratingValues(stars, urls: urls, previous: $0) },
            onChange: { [weak self] values in
                self?.origin?.slideshowDidChangeCulling(values)
                if let record = values[urls[0]] { self?.toast(Culling.ratingAnnouncement(record.rating)) }
            }, onFailure: { [weak self] error in self?.toast(CullingUndo.failureMessage(.rating, error: error)) }
        )
    }

    private func toggleFlagShown() {
        guard let index = shownIndex else { return }
        let group = groups[index]
        let urls = Culling.imageURLs(of: group)
        let leaders = [group.primary]
        let store = services.metadataStore
        let undo = origin?.slideshowUndoManager
        CullingUndo.perform(
            .flag, urls: urls, store: store, undoManager: undo,
            compute: { Culling.toggledFlagValues(urls: urls, leaders: leaders, previous: $0) },
            onChange: { [weak self] values in
                self?.origin?.slideshowDidChangeCulling(values)
                if let record = values[group.primary] { self?.toast(Culling.flagAnnouncement(record.flagged)) }
            }, onFailure: { [weak self] error in self?.toast(CullingUndo.failureMessage(.flag, error: error)) })

    }

    private func toast(_ text: String, glyph: Bool = false) {
        toastsForTesting.append(text)
        guard window != nil else { return }
        toastHost.show(ToastContent(text, kind: glyph ? .glyph : .text))
    }

    // MARK: Showing images

    private func interval() -> TimeInterval {
        intervalOverrideForTesting ?? TimeInterval(settings.intervalSec)
    }

    /// The decode list follows the play order, so the queue's window
    /// (radius 2) decodes the next two images ahead.
    private func resetQueueList() async {
        let sources: [any ImageSource] = playlist.order.map { FileImageSource(url: groups[$0].primary) }
        await queue.setNavigation(list: sources, currentIndex: playlist.position)
    }

    private func show(position: Int, animated: Bool) {
        advanceTask?.cancel()
        showGeneration += 1
        let generation = showGeneration
        let item = playlist.order[position]
        let url = groups[item].primary
        let queue = self.queue
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            // Waits for the decode: the current image stays up until the
            // next one is ready (never a black frame).
            await self?.listTask?.value
            let entry: DecodedImage
            do {
                entry = try await queue.jumpToEntry(index: position)
            } catch {
                guard let self, generation == self.showGeneration, !self.ended else { return }
                // The failed identity is explicit; no preceding photo remains.
                self.front?.setImage(nil, sourceID: nil); self.back?.setImage(nil, sourceID: nil)
                self.toast("Can’t open ‘\(url.lastPathComponent)’. Continuing after the interval.")
                self.didShow(item: item, url: url)
                return
            }
            guard let self, generation == self.showGeneration, !self.ended else { return }
            await self.present(entry, animated: animated)
            guard generation == self.showGeneration, !self.ended else { return }
            self.didShow(item: item, url: url)
        }
    }

    private func didShow(item: Int, url: URL) {
        shownIndex = item
        shownHistory.append(item)
        if !isPaused { scheduleAdvance() }
    }

    private func present(_ entry: DecodedImage, animated: Bool) async {
        guard let front, let back else { return }
        back.setImage(entry.image, sourceID: entry.sourceID, prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy)
        applyFit(back, image: entry.image)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = animated ? settings.transition.effective(reduceMotion: reduceMotion) : .cut
        back.alphaValue = transition == .cut ? 1 : 0
        back.isHidden = false
        if let superview = back.superview {
            superview.addSubview(back, positioned: .above, relativeTo: front)
        }
        if transition == .dissolve, let frames = dissolveFrames(), let layer = back.layer {
            // Noise dissolve: a pixel switches when its fixed noise value
            // is below t. Stepped mask frames over 480 ms.
            back.alphaValue = 1
            let mask = CALayer()
            mask.frame = layer.bounds
            mask.magnificationFilter = .nearest
            mask.contents = frames.last
            layer.mask = mask
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                CATransaction.begin()
                CATransaction.setCompletionBlock { done.resume() }
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = frames
                animation.duration = transition.duration
                animation.calculationMode = .discrete
                mask.add(animation, forKey: "dissolve")
                CATransaction.commit()
            }
            layer.mask = nil
        } else if transition != .cut {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = transition.duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    back.animator().alphaValue = 1
                }, completionHandler: { done.resume() })
            }
        }
        front.alphaValue = 0
        front.setImage(nil, sourceID: nil)
        self.front = back
        self.back = front
    }

    /// 16 RGBA masks (256 × 256, scaled up with nearest filtering)
    /// thresholding interleaved gradient noise at t = 1/16 … 1. Made on
    /// the first Dissolve, released with the controller.
    private var dissolveMasks: [CGImage]?

    private func dissolveFrames() -> [CGImage]? {
        if let dissolveMasks { return dissolveMasks }
        let side = 256, steps = 16
        var noise = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let f = 0.06711056 * Double(x) + 0.00583715 * Double(y)
                let v = 52.9829189 * (f - f.rounded(.down))
                noise[y * side + x] = v - v.rounded(.down)
            }
        }
        var frames: [CGImage] = []
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in 0..<(side * side) { let v: UInt8 = noise[i] < t ? 255 : 0; for c in 0..<4 { data[i * 4 + c] = v } }
            guard let image = ctx.makeImage() else { return nil }
            frames.append(image)
        }
        dissolveMasks = frames
        return frames
    }

    private func applyFit(_ view: MetalImageView, image: CGImage) {
        guard settings.fill, image.width > 0, image.height > 0 else {
            view.contentMode = .bestFit
            return
        }
        let size = view.bounds.size
        let zoom = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        view.contentMode = .zoom(Double(zoom))
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        let seconds = interval()
        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.ended, !self.isPaused else { return }
            if self.playlist.next() {
                self.show(position: self.playlist.position, animated: true)
            } else {
                self.exit(finished: true)
            }
        }
    }

    // MARK: Display sleep

    private func updateActivity() {
        if !isPaused && !ended {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Slideshow")
            }
        } else {
            endActivity()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Window

    private func buildWindow(frame: NSRect) {
        let window = SlideshowWindow(contentRect: frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]
        window.acceptsMouseMovedEvents = true
        window.title = "Slideshow"
        let root = SlideshowRootView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.onMouseMoved = { [weak self] in self?.pointerMoved() }
        window.contentView = root
        let a = MetalImageView(frame: root.bounds)
        let b = MetalImageView(frame: root.bounds)
        for view in [a, b] {
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        b.alphaValue = 0
        front = a
        back = b

        pauseIndicator.translatesAutoresizingMaskIntoConstraints = false
        pauseIndicator.isHidden = true
        root.addSubview(pauseIndicator)
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.alphaValue = 0
        root.addSubview(controlBar)
        NSLayoutConstraint.activate([
            pauseIndicator.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            pauseIndicator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            controlBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            controlBar.heightAnchor.constraint(equalToConstant: 44),
        ])
        toastHost.install(in: root)
        controlBar.sync(settings: settings, paused: isPaused)
        controlBar.onAction = { [weak self] action in self?.handleBar(action) }

        window.onKey = { [weak self] event in
            guard let self else { return false }
            let fastStone = Prefs.shortcutPreset == .fastStoneCompat
            guard let action = SlideshowKeyAction.action(for: event, fastStone: fastStone) else { return false }
            self.handle(action)
            return true
        }
        window.delegate = self
        self.window = window
        savedPresentation = NSApp.presentationOptions
        window.makeKeyAndOrderFront(nil)
        schedulePointerHide()
    }

    private func handleBar(_ action: SlideshowControlBar.Action) {
        switch action {
        case .previous: handle(.previous)
        case .playPause: handle(.togglePause)
        case .next: handle(.next)
        case .interval(let s): setInterval(s)
        case .transition(let t): setTransition(t)
        case .random(let on): setRandom(on)
        case .loop(let on): setLoop(on)
        case .exit: exit(finished: false)
        }
        pointerMoved()
    }

    /// Pointer hides after 1.5 s still; moving it shows the bar for 2 s.
    private func pointerMoved() {
        NSCursor.unhide()
        controlBar.animator().alphaValue = 1
        barTimer?.invalidate()
        barTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.controlBar.isPointerInside else { return }
                self.controlBar.animator().alphaValue = 0
            }
        }
        schedulePointerHide()
    }

    private func schedulePointerHide() {
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            Task { @MainActor in NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    func windowDidResignKey(_ notification: Notification) {
        NSApp.presentationOptions = savedPresentation
    }
}

// MARK: - Window and views

@MainActor
final class SlideshowWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
final class SlideshowRootView: NSView {
    var onMouseMoved: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
    override var acceptsFirstResponder: Bool { true }
}

/// Pause indicator: a small HUD glyph while paused.
@MainActor
final class SlideshowPauseIndicator: HUDSurfaceView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        // HUD recipe (solid surface, hairline, shadow).
        wantsLayer = true
        glassShape = .capsule
        isFullScreenHUD = true
        let image = NSImageView(image: NSImage(systemSymbolName: "pause.fill",
                                               accessibilityDescription: "Paused")!)
        image.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("Paused")
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Control bar, 44 pt: Previous · Play/Pause · Next ·
/// interval · transition · Random · Loop · Exit. No volume.
@MainActor
final class SlideshowControlBar: HUDSurfaceView {

    enum Action: Equatable {
        case previous, playPause, next, exit
        case interval(Int), transition(SlideshowTransition), random(Bool), loop(Bool)
    }

    static let intervals = [1, 2, 3, 4, 5, 7, 10, 15, 20, 30, 45, 60]

    var onAction: ((Action) -> Void)?
    private(set) var isPointerInside = false

    private let playButton = SlideshowControlBar.button("pause.fill", "Pause")
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transitionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let randomButton = SlideshowControlBar.button("shuffle", "Random")
    private let loopButton = SlideshowControlBar.button("repeat", "Loop")

    init() {
        super.init(frame: .zero)
        // HUD recipe (solid surface on macOS 14/15, tinted
        // glass capsule on 26), the same as the viewer's floating bar.
        wantsLayer = true
        glassShape = .capsule
        isFullScreenHUD = true
        let prev = Self.button("backward.fill", "Previous")
        let next = Self.button("forward.fill", "Next")
        let exit = Self.button("xmark", "Exit Slideshow")
        prev.target = self; prev.action = #selector(prevClicked)
        next.target = self; next.action = #selector(nextClicked)
        exit.target = self; exit.action = #selector(exitClicked)
        playButton.target = self; playButton.action = #selector(playClicked)
        randomButton.setButtonType(.pushOnPushOff)
        loopButton.setButtonType(.pushOnPushOff)
        randomButton.target = self; randomButton.action = #selector(randomClicked)
        loopButton.target = self; loopButton.action = #selector(loopClicked)
        intervalPopup.addItems(withTitles: Self.intervals.map { "\($0) s" })
        intervalPopup.target = self; intervalPopup.action = #selector(intervalChosen)
        intervalPopup.setAccessibilityLabel("Seconds per image")
        transitionPopup.addItems(withTitles: SlideshowTransition.allCases.map(\.title))
        transitionPopup.target = self; transitionPopup.action = #selector(transitionChosen)
        transitionPopup.setAccessibilityLabel("Transition")
        for popup in [intervalPopup, transitionPopup] { popup.controlSize = .small }
        let stack = NSStackView(views: [prev, playButton, next, intervalPopup, transitionPopup,
                                        randomButton, loopButton, exit])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let b = NSButton(image: image, target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    func sync(settings: SlideshowSettings, paused: Bool) {
        let symbol = paused ? "play.fill" : "pause.fill"
        let label = paused ? "Play" : "Pause"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        playButton.toolTip = label
        playButton.setAccessibilityLabel(label)
        let title = "\(settings.intervalSec) s"
        if intervalPopup.item(withTitle: title) == nil {
            intervalPopup.addItem(withTitle: title)
        }
        intervalPopup.selectItem(withTitle: title)
        transitionPopup.selectItem(withTitle: settings.transition.title)
        randomButton.state = settings.random ? .on : .off
        loopButton.state = settings.loop ? .on : .off
        randomButton.contentTintColor = settings.random ? ShrikeAccent.mark : .white
        loopButton.contentTintColor = settings.loop ? ShrikeAccent.mark : .white
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    @objc private func prevClicked() { onAction?(.previous) }
    @objc private func nextClicked() { onAction?(.next) }
    @objc private func playClicked() { onAction?(.playPause) }
    @objc private func exitClicked() { onAction?(.exit) }
    @objc private func randomClicked() { onAction?(.random(randomButton.state == .on)) }
    @objc private func loopClicked() { onAction?(.loop(loopButton.state == .on)) }
    @objc private func intervalChosen() {
        let n = Int(intervalPopup.titleOfSelectedItem?.split(separator: " ").first ?? "") ?? 4
        onAction?(.interval(n))
    }
    @objc private func transitionChosen() {
        let t = SlideshowTransition.allCases[max(0, transitionPopup.indexOfSelectedItem)]
        onAction?(.transition(t))
    }
}

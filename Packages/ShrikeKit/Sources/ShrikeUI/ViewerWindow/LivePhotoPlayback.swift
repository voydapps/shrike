//
//  LivePhotoPlayback.swift
//  ShrikeUI
//
//  Plays a Live Photo's movie over the still, once, then
//  crossfades back to the still in 240 ms. The movie sits in its own
//  view just above the Metal image view, framed to the photo's drawn
//  rectangle, so panels and badges stay above it.
//
//  Cost: nothing from AVFoundation is made before the first play (the
//  framework itself is already in the process: AppKit / Core Image load
//  it at launch, measured). `release()` frees the player and
//  its view; the canvas calls it on navigation and on window close.
//

import AppKit
import AVFoundation

/// The movie's view: an `AVPlayerLayer` as the backing layer. Clicks and
/// the pointer pass through to the canvas under it.
@MainActor
final class LivePhotoMovieView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class LivePhotoPlayback {

    enum State: Equatable {
        /// Nothing on screen.
        case idle
        /// Asked to play; the movie is loading.
        case loading
        /// The movie is on screen and running.
        case playing
        /// The clip ended; fading back to the still.
        case fadingOut
    }

    /// `motion.crossfade`.
    static let crossfadeDuration: TimeInterval = 0.24

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// The movie could not be loaded or played: the canvas hides the badge
    /// for this photo.
    var onLoadFailed: ((URL) -> Void)?
    var onStateChange: ((State) -> Void)?

    /// The canvas the movie view goes in, and the view it sits above.
    private weak var host: NSView?
    private weak var imageView: NSView?
    /// The photo's drawn rectangle in `host` coordinates.
    private let imageRect: () -> CGRect

    private var movieURL: URL?
    private(set) var player: AVPlayer?
    private(set) var movieView: LivePhotoMovieView?
    private var observers: [any NSObjectProtocol] = []
    private var loadTask: Task<Void, Never>?
    /// Bumped by every play / stop, so a late load or fade does nothing.
    private var generation = 0

    init(host: NSView, above imageView: NSView, imageRect: @escaping () -> CGRect) {
        self.host = host
        self.imageView = imageView
        self.imageRect = imageRect
    }

    var isActive: Bool { state != .idle }
    /// Loading or running (not the fade back).
    var isPlaying: Bool { state == .loading || state == .playing }
    var isMuted: Bool? { player?.isMuted }

    // MARK: Play

    /// Plays `url` once from the start. Muted unless `withSound`.
    func play(_ url: URL, withSound: Bool) {
        if isPlaying, movieURL == url { player?.isMuted = !withSound; return }
        if let player, movieURL == url {
            // Same photo again: the player is ready, start over.
            stop()
            generation &+= 1
            let gen = generation
            player.isMuted = !withSound
            state = .loading
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.startPlaying()
                }
            }
            return
        }
        release()
        let gen = generation
        movieURL = url
        state = .loading
        loadTask = Task { [weak self] in
            let playable = await Self.canPlay(url)
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.loadTask = nil
            guard playable else { self.fail(url); return }
            self.makePlayer(url, muted: !withSound)
            self.startPlaying()
        }
    }

    /// True when `url` loads and has a video track (off the main actor).
    nonisolated private static func canPlay(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            return try await !asset.loadTracks(withMediaType: .video).isEmpty
        } catch {
            return false
        }
    }

    private func makePlayer(_ url: URL, muted: Bool) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player

        let view = LivePhotoMovieView(frame: imageRect())
        view.alphaValue = 0
        view.playerLayer?.player = player
        if let host, let imageView, imageView.superview === host {
            host.addSubview(view, positioned: .above, relativeTo: imageView)
        } else {
            host?.addSubview(view)
        }
        movieView = view

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                            object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                            object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let url = self.movieURL else { return }
                self.fail(url)
            }
        })
    }

    private func startPlaying() {
        guard let player, let view = movieView else { return }
        updateFrame()
        view.isHidden = false
        view.alphaValue = 1
        state = .playing
        player.play()
    }

    private func fail(_ url: URL) {
        release()
        onLoadFailed?(url)
    }

    // MARK: End, stop, release

    /// The clip ended: crossfade back to the still.
    private func didPlayToEnd() {
        guard state == .playing, let view = movieView else { return }
        state = .fadingOut
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.crossfadeDuration
            ctx.allowsImplicitAnimation = true
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.state == .fadingOut else { return }
                self.movieView?.isHidden = true
                self.player?.pause()
                self.state = .idle
            }
        })
    }

    /// Stops at once: the still returns with no fade (pointer left the
    /// photo, a key, a zoom). The player stays for a replay.
    func stop() {
        guard state != .idle else { return }
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        player?.pause()
        if let view = movieView {
            view.alphaValue = 0
            view.isHidden = true
        }
        state = .idle
    }

    /// Stops and frees the player and its view (navigation, close).
    func release() {
        stop()
        generation &+= 1
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        movieView?.playerLayer?.player = nil
        movieView?.removeFromSuperview()
        movieView = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        movieURL = nil
    }

    /// Follows the photo's drawn rectangle (window resize at fit).
    func updateFrame() {
        guard let view = movieView else { return }
        let rect = imageRect()
        if view.frame != rect { view.frame = rect }
    }

    /// Where the movie is drawn (host coordinates), or nil when hidden.
    var visibleFrame: CGRect? {
        guard isActive, let view = movieView, !view.isHidden else { return nil }
        return view.frame
    }
}

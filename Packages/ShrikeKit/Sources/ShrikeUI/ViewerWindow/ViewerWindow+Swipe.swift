//
//  ViewerWindow+Swipe.swift
//  ShrikeUI
//
//  Host side of the paging swipe: the neighbour's picture
//  for the slide, and the hand-over when the swipe completes. The slide
//  never waits for a decode: the prefetched texture if there is one, else
//  the thumbnail (and the decode queue puts that photo first), else an
//  empty page.
//

import AppKit
import ShrikeCore
import ShrikeRendering

extension ViewerWindow {

    /// Answers `wantsSwipeNeighbour`, never waiting on the main thread.
    func supplySwipeNeighbour(forward: Bool) {
        reviewDecisionSerial &+= 1
        let index = intent.currentIndex + (forward ? 1 : -1)
        guard index >= 0, index < list.count else { return }
        let nav = navigation
        let url = (intent.sourceAt(index) as? FileImageSource)?.url
        let maxThumb = Self.thumbBridgeMaxPixelSize
        Task { @MainActor [weak self] in
            // 1. The prefetch window (the normal case).
            if let entry = await nav.cachedEntry(at: index),
               let texture = entry.prepared as? DisplayTexture {
                self?.contentRoot.imageView.setSwipeNeighbour(texture, forward: forward)
                return
            }
            // Not decoded yet: that photo goes first. When it lands during
            // the slide, it replaces the stand-in from the next frame.
            Task { @MainActor [weak self] in
                guard let entry = await nav.prioritizeNeighbour(at: index),
                      let texture = entry.prepared as? DisplayTexture else { return }
                self?.contentRoot.imageView.setSwipeNeighbour(texture, forward: forward)
            }
            // 2. The thumbnail, at the photo's Fit rect.
            let logical = Task.detached(priority: .userInitiated) { () -> CGSize? in
                url.flatMap { WindowTitles.headerPixelSize(of: $0) }
            }
            guard let thumb = await nav.thumbnail(at: index, maxPixelSize: maxThumb) else { return }
            let texture = await Task.detached(priority: .userInitiated) {
                DisplayTextureFactory.make(from: thumb, commandQueue: nil, waitUntilCompleted: true)
            }.value
            let size = await logical.value
            guard let texture else { return }
            self?.contentRoot.imageView.setSwipeNeighbour(
                texture, forward: forward, isStandIn: true, logicalSize: size)
        }
    }

    /// A swipe completed: the view already shows the neighbour's picture.
    /// Navigate exactly as → / ← does (chrome changes now, at completion),
    /// telling the navigation what is on screen.
    func completeSwipe(forward: Bool, handOver: SwipeHandOver) {
        let target = intent.currentIndex + (forward ? 1 : -1)
        pendingSwipeHandOver = (target, handOver)
        dispatch(forward ? .nextImage : .prevImage)
    }

    /// The hand-over for a navigation to `index`, used once.
    func takeSwipeHandOver(for index: Int) -> SwipeHandOver? {
        defer { pendingSwipeHandOver = nil }
        guard let pending = pendingSwipeHandOver, pending.index == index else { return nil }
        return pending.handOver
    }
}

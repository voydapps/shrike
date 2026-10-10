//
//  ViewerWindow+FullResolution.swift
//  ShrikeUI
//
//  Past the display texture's
//  resolution the viewer swaps in the full-resolution decode in place.
//  At most one full-resolution texture per window; navigation cancels
//  it and a return to Fit drops it, so the memory comes back.
//

import AppKit
import ShrikeCore
import ShrikeRendering

extension ViewerWindow {

    /// The hairline shows only when the decode takes longer.
    static let fullResolutionHairlineDelay: TimeInterval = 0.150

    /// Called on every zoom change (and when the file's pixel size lands).
    func requestFullResolutionIfNeeded() {
        let view = contentRoot.imageView
        if view.isShowingFullResolution {
            if view.isAtFit, !view.isZoomAnimating { view.dropFullResolution() }
            return
        }
        guard fullResTask == nil, !contentRoot.isEditModeActive,
              view.wantsFullResolution, let item = displayedItem else { return }
        let index = item.listIndex
        let sourceID = view.sourceID
        let nav = navigation
        let hairline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fullResolutionHairlineDelay * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.contentRoot.showHairlineIndicatorImmediately(predicted: 0.4)
            self.fullResHairlineShown = true
        }
        fullResTask = Task { @MainActor [weak self] in
            defer {
                hairline.cancel()
                if let self {
                    if self.fullResHairlineShown { self.contentRoot.completeHairlineIndicator() }
                    self.fullResHairlineShown = false
                    self.fullResTask = nil
                }
            }
            let queue = await nav.decodeQueue
            guard let entry = try? await queue.loadFullResolution(at: index),
                  !Task.isCancelled, let self else { return }
            // Land a running double-click animation first (its steps are
            // in the old texture's units).
            var waits = 0
            while view.isZoomAnimating, waits < 40, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                waits += 1
            }
            guard !Task.isCancelled, self.displayedItem == item,
                  !self.contentRoot.isEditModeActive, !view.isAtFit else { return }
            view.swapInFullResolution(entry.image, prepared: entry.prepared as? DisplayTexture,
                                      sourceID: sourceID)
        }
    }

    /// Navigation: stop the decode (the next photo replaces the texture).
    func cancelFullResolution() {
        fullResTask?.cancel()
        fullResTask = nil
    }
}

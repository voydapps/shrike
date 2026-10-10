//
//  ViewerWindow+Launch.swift
//  ShrikeUI
//
//  (launch speed): the first photo goes on the canvas before
//  the window is ordered front, when its texture is already decoded (the
//  `DecodeHandoff` early decode usually is by then). The first frame on
//  screen is then the photo, not an empty canvas that waits one more
//  run-loop turn (about 50-90 ms at launch) for the first navigation.
//

import AppKit
import ShrikeCore
import ShrikeRendering

extension ViewerWindow {

    /// Puts the start photo on the canvas when the decode queue already
    /// holds its texture. Never waits for a decode: false when it is not
    /// ready (the normal first navigation paints it). The canvas is laid
    /// out first (the layout AppKit would do on order front anyway), so
    /// the one frame this asks for has its real size. The first
    /// navigation still runs and finds the same texture (cached, no
    /// stand-in, no flash).
    @discardableResult
    func paintReadyFirstPhoto() async -> Bool {
        guard displayedItem == nil, !didTearDown else { return false }
        if paintReadyFirstPhotoNow() { return true }
        let index = intent.currentIndex
        let wait = ShrikeSignposts.launch.begin("readyPhotoWait")
        let cached = await navigation.cachedEntry(at: index)
        ShrikeSignposts.launch.end("readyPhotoWait", wait, cached == nil ? "miss" : "hit")
        guard let entry = cached else { return false }
        // The first navigation (or a key press) may have painted meanwhile.
        guard displayedItem == nil, !didTearDown, intent.currentIndex == index else { return false }
        let layout = ShrikeSignposts.launch.begin("firstLayout")
        contentView?.layoutSubtreeIfNeeded()
        ShrikeSignposts.launch.end("firstLayout", layout)
        let set = ShrikeSignposts.launch.begin("readyPhotoSetImage")
        contentRoot.setImage(
            entry.image, index: index, total: list.count,
            sourceID: intent.sourceAt(index)?.id,
            prepared: entry.prepared as? DisplayTexture
        )
        markDisplayed(index)
        ShrikeSignposts.launch.end("readyPhotoSetImage", set)
        ShrikeSignposts.launch.event("readyPhotoBeforeOrderFront", "idx=\(index)")
        return true
    }

    /// The same, with no wait at all, when
    /// the decode queue already holds the start photo's finished entry
    /// (the early `DecodeHandoff` decode usually lands while the window
    /// is being built). The photo then goes on the canvas and the window
    /// is ordered front in the same run-loop turn that built it: AppKit
    /// lays the new window out and draws it once, already key and on
    /// screen, instead of first laying out and drawing the hidden window
    /// (~45 ms at launch) and only then taking the photo.
    @discardableResult
    func paintReadyFirstPhotoNow() -> Bool {
        guard displayedItem == nil, !didTearDown else { return false }
        let index = intent.currentIndex
        guard let sourceID = intent.sourceAt(index)?.id,
              let entry = navigation.readyEntryNow(sourceID: sourceID) else { return false }
        paintFirstPhoto(entry, index: index, sourceID: sourceID, event: "readyPhotoNow")
        return true
    }

    /// Lays the canvas out and puts `entry` on it as the first photo.
    private func paintFirstPhoto(_ entry: DecodedImage, index: Int, sourceID: String, event: StaticString) {
        let layout = ShrikeSignposts.launch.begin("firstLayout")
        contentView?.layoutSubtreeIfNeeded()
        ShrikeSignposts.launch.end("firstLayout", layout)
        let set = ShrikeSignposts.launch.begin("readyPhotoSetImage")
        contentRoot.setImage(
            entry.image, index: index, total: list.count,
            sourceID: sourceID, prepared: entry.prepared as? DisplayTexture
        )
        markDisplayed(index)
        ShrikeSignposts.launch.end("readyPhotoSetImage", set)
        ShrikeSignposts.launch.event(event, "idx=\(index)")
    }

    /// How long after the window is built it
    /// may stay hidden while the early decode of its first photo ends.
    /// Measured (18 MP JPEG, load ~16): the decode lands 25, 31, 34 and
    /// 43 ms after the window is built; quiet, ~18 ms. A miss is costly:
    /// the window then stays empty ~160 ms (AppKit's first display holds
    /// the main thread before the first navigation paints), so the cap
    /// covers the loaded case too. Past it the window is shown without
    /// the photo (as before), so a slow file never holds it back long.
    /// Counted from the start of `orderFrontWithReadyPhoto`, right after
    /// the window is built; the first layout (~20 ms) is inside it.
    static let firstPhotoWaitCapMs = 50

    /// When the early `DecodeHandoff` decode of the start
    /// photo is still running, waits for it (blocking the main thread
    /// until `deadline` at most) and puts it on the canvas. The decode
    /// runs on a background lane and needs nothing from the main thread;
    /// the queue that claimed it holds the same texture, so nothing is
    /// decoded or kept twice.
    @discardableResult
    func paintHandoffFirstPhoto(url: URL, deadline: DispatchTime) -> Bool {
        guard displayedItem == nil, !didTearDown else { return false }
        let index = intent.currentIndex
        guard let source = intent.sourceAt(index) else { return false }
        let want = Self.initialTextureLongEdge(frame: frame)
        let wait = ShrikeSignposts.launch.begin("handoffWait")
        let entry = DecodeHandoff.shared.waitForFinished(url: url, target: want, deadline: deadline)
        ShrikeSignposts.launch.end("handoffWait", wait, entry == nil ? "miss" : "hit")
        guard let entry, !didTearDown, displayedItem == nil, intent.currentIndex == index else { return false }
        paintFirstPhoto(entry, index: index, sourceID: source.id, event: "handoffPhoto")
        return true
    }

    /// Orders the window front after putting a ready first photo on the
    /// canvas (see `paintReadyFirstPhoto`). When the photo is already
    /// decoded this runs to the end without suspending.
    func orderFrontWithReadyPhoto() async {
        let deadline = DispatchTime.now() + .milliseconds(Self.firstPhotoWaitCapMs)
        // The start photo's early decode, when one is running (a cold
        // open or a Finder open of one photo).
        var handoffURL: URL?
        if let file = intent.sourceAt(intent.currentIndex) as? FileImageSource,
           DecodeHandoff.shared.hasWaitableDecode(url: file.url) {
            handoffURL = file.url
        }
        defer { if let handoffURL { DecodeHandoff.shared.forgetFinished(url: handoffURL) } }
        if !paintReadyFirstPhotoNow() {
            // The early decode usually lands a few ms after the window is
            // built. Do the first layout now (it is needed anyway, ~20-40
            // ms at launch) and look again: when it landed meanwhile, the
            // photo and the window still go up in this turn.
            let layout = ShrikeSignposts.launch.begin("firstLayout")
            contentView?.layoutSubtreeIfNeeded()
            ShrikeSignposts.launch.end("firstLayout", layout)
            if !paintReadyFirstPhotoNow() {
                if let handoffURL {
                    // Wait (bounded) for the early decode
                    // itself, so the window does not go up empty. Past
                    // the cap the window goes up at once.
                    paintHandoffFirstPhoto(url: handoffURL, deadline: deadline)
                } else {
                    await paintReadyFirstPhoto()
                }
            }
        }
        guard !didTearDown else { return }
        let front = ShrikeSignposts.launch.begin("viewerOrderFront")
        makeKeyAndOrderFront(nil)
        ShrikeSignposts.launch.end("viewerOrderFront", front)
        // After the first pixel, never before it.
        feedHistogramWithShownPhoto()
    }

    /// The first photo painted here has its
    /// histogram even when the first navigation does not reach its end
    /// (superseded by a texture-size change or a list reload). A no-op
    /// when that navigation already fed it. The sample decode runs off
    /// the main thread after the histogram's 30 ms settle.
    func feedHistogramWithShownPhoto() {
        guard let item = displayedItem, !didTearDown else { return }
        contentRoot.feedHistogramIfMissing(url: item.group.primary)
    }
}

// MARK: - First texture size

extension ViewerWindow {

    /// Frame the next viewer will get (`WindowCoordinator.openViewer`
    /// with an explicit frame, e.g. a Browser's). Read once by the next
    /// init. Nil: the saved "shrike.viewer" frame.
    static var nextFrameHint: NSRect?

    /// The texture size a new viewer
    /// decodes its first photos at, before its first layout knows the
    /// canvas. It used to be the whole screen (5120 px on a 5K display,
    /// capped at 4096), so the start photo and its neighbours kept
    /// 4096 px textures (~45 MB each for an 18 MP photo) while a
    /// 1200 x 800 pt window needs 2400 px (~15 MB). Now: the window's
    /// long edge at the screen's scale, from `frame` or the saved viewer
    /// frame, never above the screen or the max-long-edge pref. The
    /// canvas is never larger than the window, so the first layout asks
    /// for nothing larger and the photo is decoded once.
    /// `DecodeHandoff` (the cold-open decode) uses the same size, so the
    /// viewer's queue can take that decode over.
    static func initialTextureLongEdge(frame: NSRect? = nil) -> Int {
        let pref = Prefs.maxDisplayLongEdge
        guard let screen = NSScreen.main else { return pref }
        let visible = screen.visibleFrame.size
        var size = frame?.size ?? savedFrameSize() ?? NSSize(width: 1200, height: 800)
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        let px = Int((max(size.width, size.height) * screen.backingScaleFactor).rounded(.up))
        return max(256, min(pref, px))
    }

    /// Takes the frame hint (one use) and returns the first texture size.
    static func takeInitialTextureLongEdge() -> Int {
        let hint = nextFrameHint
        nextFrameHint = nil
        return initialTextureLongEdge(frame: hint)
    }

    /// Size part of AppKit's saved "NSWindow Frame shrike.viewer" string
    /// ("x y w h screenX screenY screenW screenH"). AppKit's own
    /// autosave key, so it lives in `UserDefaults.standard`.
    static func savedFrameSize() -> NSSize? {
        let key = "NSWindow Frame \(frameAutosaveName)"
        return frameSize(saved: UserDefaults.standard.string(forKey: key))
    }

    static func frameSize(saved: String?) -> NSSize? {
        guard let saved else { return nil }
        let parts = saved.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return NSSize(width: parts[2], height: parts[3])
    }
}

// MARK: - Texture size follows the window

extension ViewerWindow {

    /// The canvas texture size changed: the decode queue aims at it, and
    /// when the shown photo's texture is now smaller than the canvas (and
    /// than the file), the same photo is fetched again at the larger size
    /// and swapped in without resetting zoom and without a flash. When the
    /// texture is much larger than the canvas (leaving full screen), it is
    /// swapped for a smaller one the same way.
    func textureLongEdgeChanged(to px: Int) {
        textureLongEdgeForTesting = px
        let navigation = self.navigation
        Task { @MainActor [weak self] in
            let queue = await navigation.decodeQueue
            await queue.setMaxLongEdge(px)
            self?.refetchDisplayedIfTextureSmall(than: px)
        }
    }

    func refetchDisplayedIfTextureSmall(than px: Int) {
        let view = contentRoot.imageView
        guard let item = displayedItem, !contentRoot.isEditModeActive,
              let shown = view.displayTextureLongEdge else { return }
        // A texture made for full screen is swapped
        // for a canvas-sized one when the window is small again (25 %
        // slack), so the big texture is released.
        let tooBig = shown > px + px / 4
        guard shown < px || tooBig else { return }
        // A file smaller than the canvas already has all its pixels.
        if !tooBig, let source = view.sourcePixelSize, Int(max(source.width, source.height)) <= shown { return }
        let index = item.listIndex
        // Only while no navigation is on its way (it would decode at the
        // new size anyway, and must keep the queue's cursor).
        guard intent.currentIndex == index else { return }
        let url = item.group.primary
        let navigation = self.navigation
        textureRefetchTask?.cancel()
        textureRefetchTask = Task { @MainActor [weak self] in
            guard let entry = try? await navigation.jumpEntry(to: index), !Task.isCancelled,
                  let self, self.displayedItem?.group.primary == url,
                  !self.contentRoot.isEditModeActive,
                  tooBig ? max(entry.image.width, entry.image.height) < shown
                         : max(entry.image.width, entry.image.height) > shown else { return }
            if view.swapInLargerDisplayTexture(entry.image, prepared: entry.prepared as? DisplayTexture,
                                               sourceID: entry.sourceID) {
                self.textureRefetchCount &+= 1
                // A texture-size change can supersede the
                // first navigation before it fed the histogram.
                self.feedHistogramWithShownPhoto()
            }
        }
    }
}

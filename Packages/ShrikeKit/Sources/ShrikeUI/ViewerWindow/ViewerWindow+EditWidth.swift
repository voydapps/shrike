//
//  ViewerWindow+EditWidth.swift
//  ShrikeUI
//
//  Spec 27 V7 and N2: edit mode has its own minimum canvas width (648 pt).
//  Entering edit in a window: the inspector steps aside first when the canvas
//  is narrower, then the window widens (left edge fixed, shifted back inside
//  the screen when needed). While editing the window cannot shrink below it.
//  Leaving edit gives the old size back unless the user resized meanwhile.
//  Full screen is not affected. The edit toolbar is shown whenever edit starts.
//

import AppKit
import ShrikeRendering

extension ViewerWindow {

    /// 150 ms, but only for the edit-width resize (`setEditWidthFrame`); every other
    /// animated resize (the zoom button, ...) keeps the system's own time.
    override public func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        editWidthResizing ? EditLayout.resizeDuration : super.animationResizeTime(newFrame)
    }

    /// Whether the window is in full screen (tests can pretend).
    var inFullScreenNow: Bool { fullScreenOverrideForTesting ?? styleMask.contains(.fullScreen) }

    /// Sets the widened or returned frame; the system asks for the time during this call.
    private func setEditWidthFrame(_ target: NSRect) {
        editWidthResizing = true
        defer { editWidthResizing = false }
        setFrame(target, display: true, animate: isVisible && !ReduceMotion.isOn)
    }

    /// Edit mode started or ended (called by the content view).
    func editModeLayoutChanged(active: Bool) {
        editLayoutActive = active
        if active {
            splitController?.editModeChanged(active: true)
            guard contentRoot.windowMode == .windowed, !inFullScreenNow else { return }
            makeRoomForEditing()
            // Spec 27 N2: the edit toolbar is never left hidden by the auto-hide.
            autoHider?.show(animated: false)
        } else {
            // Decide on the width before the inspector comes back: reopening it makes
            // the split view grow the window, and the old size is set after that.
            let target = widthReturnTarget()
            splitController?.editModeChanged(active: false)
            if let target { setEditWidthFrame(target) }
        }
    }

    /// While editing in a window, a frame narrower than the minimum canvas is
    /// widened at once. `contentMinSize` only stops a drag; `setFrame` from code
    /// or from Accessibility goes past it, and the 296 pt tool column then
    /// covered half the photo (audit 2026-10-13, item 3).
    @objc func editWindowDidResize(_ note: Notification) {
        guard editLayoutActive, !editWidthResizing, !inFullScreenNow,
              contentRoot.windowMode == .windowed else { return }
        let content = contentRect(forFrameRect: frame).width
        guard content < EditLayout.minCanvasWidth - 0.5 else { return }
        // The inspector gives its room back first, as on entry.
        splitController?.editCanvasWidth(editCanvasWidthNow)
        let now = contentRect(forFrameRect: frame).width
        guard now < EditLayout.minCanvasWidth - 0.5 else { return }
        var target = frame
        target.size.width += EditLayout.minCanvasWidth - now
        let visible = editScreenVisibleFrameForTesting ?? screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible, target.maxX > visible.maxX {
            target.origin.x = max(visible.minX, visible.maxX - target.width)
        }
        editWidenRestore = (editWidenRestore?.original ?? frame, target)
        setEditWidthFrame(target)
    }

    /// Full screen ended after an edit that widened the window ended inside it:
    /// the old window size comes back now (the widened frame is what AppKit restored).
    func finishEditWidthReturnAfterFullScreen() {
        guard editWidenReturnPending, !inFullScreenNow else { return }
        editWidenReturnPending = false
        // A new edit started inside full screen and is still going: the window keeps its
        // width (edit minimum back in place); the normal edit exit gives the size back.
        if editLayoutActive {
            contentMinSize = NSSize(width: EditLayout.minCanvasWidth, height: contentMinSize.height)
            return
        }
        if let target = widthReturnTarget() { setEditWidthFrame(target) }
    }

    /// The canvas width now: the window's content minus the open inspector column.
    var editCanvasWidthNow: CGFloat {
        let content = contentRect(forFrameRect: frame).width
        return content - (splitController?.inspectorColumnWidth ?? 0)
    }

    private func makeRoomForEditing() {
        // 1. The inspector steps aside when the canvas is too narrow.
        splitController?.editCanvasWidth(editCanvasWidthNow)
        // 2. The window widens when it is still narrower than the minimum canvas.
        let need = EditLayout.minCanvasWidth
        let contentWidth = contentRect(forFrameRect: frame).width
        if contentWidth < need - 0.5, editWidenRestore == nil {
            let original = frame
            var target = original
            target.size.width += need - contentWidth
            let visible = editScreenVisibleFrameForTesting ?? screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let visible, target.maxX > visible.maxX {
                target.origin.x = max(visible.minX, visible.maxX - target.width)
            }
            editWidenRestore = (original, target)
            setEditWidthFrame(target)
        }
        // 3. While editing the window does not shrink below it.
        contentMinSize = NSSize(width: need, height: contentMinSize.height)
    }

    /// The frame to go back to, or nil (nothing was widened, the user resized the
    /// window meanwhile, or it is in full screen). Also lets the window shrink again.
    private func widthReturnTarget() -> NSRect? {
        minSize = EditLayout.windowMinSize
        guard let restore = editWidenRestore else { return nil }
        // Edit ended in full screen: keep the sizes; the return happens when full screen ends.
        if inFullScreenNow { editWidenReturnPending = true; return nil }
        editWidenRestore = nil
        // Only when the width is still the one we gave; a window the user resized stays.
        guard abs(frame.width - restore.widened.width) < 1 else { return nil }
        var target = frame
        target.size.width = restore.original.width
        // A window the user moved keeps its place; an untouched one returns to its left edge.
        if abs(frame.origin.x - restore.widened.origin.x) < 1 { target.origin.x = restore.original.origin.x }
        return target
    }
}

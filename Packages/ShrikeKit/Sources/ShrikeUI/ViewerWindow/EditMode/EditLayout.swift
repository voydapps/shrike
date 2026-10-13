//
//  EditLayout.swift
//  ShrikeUI
//
//  Spec 27 V7: edit mode has its own minimum window width. The canvas holds
//  the tool column (280 pt panel + 16 pt trailing gap), a crop-handle margin
//  on each side, and a photo at least as wide as the smallest window edge
//  the viewer already accepts.
//

import AppKit

@MainActor
enum EditLayout {
    /// The tool panel column: the panel and its trailing gap.
    static let columnWidth: CGFloat = EditParameterPanel.panelWidth + 16
    /// Room kept around the photo so every crop handle can be hit.
    static let handleMargin: CGFloat = 16
    /// The least photo width worth editing: the window's smallest accepted edge.
    static let minPhotoEdge: CGFloat = 320
    /// 296 + 2 x 16 + 320 = 648 pt of canvas.
    static let minCanvasWidth: CGFloat = columnWidth + 2 * handleMargin + minPhotoEdge
    /// The ordinary window minimum (frame), restored when edit ends.
    static let windowMinSize = NSSize(width: 480, height: 320)
    /// How long the window takes to widen or return.
    static let resizeDuration: TimeInterval = 0.15
}

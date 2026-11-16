//
//  EditLayout.swift
//  ShrikeUI
//
//  Edit mode has its own minimum window width. The canvas holds
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
    /// Crop and Resize share one label column (right-aligned) and one field
    /// width, so the number fields start at the same x in both tools.
    static let fieldLabelColumnWidth: CGFloat = 48
    static let numericFieldWidth: CGFloat = 80
    static let handleMargin: CGFloat = 16
    /// The least photo width worth editing: the window's smallest accepted edge.
    static let minPhotoEdge: CGFloat = 320
    /// 296 + 2 x 16 + 320 = 648 pt of canvas holds the tools. The
    /// minimum is where the WHOLE edit toolbar fits in the icons form (picker 5 x 32 pt), so
    /// nothing is in » at the minimum. Measured on screen (macOS 26, a 41-character
    /// file name, `Editing · Unsaved changes`, Save Copy… shown, `Save Changes` primary):
    /// icons fit down to 880 pt, words down to 1100 pt (`EditPickerFormRule`); each number is
    /// the measured one plus 20 pt. (720 pt held only Cancel and Done with words.)
    static let minCanvasWidth: CGFloat = max(columnWidth + 2 * handleMargin + minPhotoEdge, 900)
    /// The ordinary window minimum (frame), restored when edit ends.
    static let windowMinSize = NSSize(width: 480, height: 320)
    /// How long the window takes to widen or return.
    static let resizeDuration: TimeInterval = 0.15
}
